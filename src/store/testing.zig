const std = @import("std");
const platform = @import("../store_path.zig");
const tool_defs = @import("../tools.zig");
const named_scratch = @import("../named_scratch.zig");
const protocol = @import("../protocol.zig");
const isBounded = @import("../bounded.zig").isBounded;
const Bounded = @import("../bounded.zig").Bounded;
const session_id = @import("../session_id.zig");
const action_domain = @import("domain/action.zig");
const change_ring = @import("../change_ring.zig");
const wire_request = @import("../wire_request.zig");
const output_format = @import("../output_format.zig");
const output_decode = @import("../output_decode.zig");
const store_core = @import("Store.zig");
const rsql = @import("rsql.zig");
const sqlite = @import("sqlite.zig");
const mysql_testing = @import("mysql_testing.zig");
const mysql_dialect_check = @import("mysql_dialect_check.zig");
const required_engines = @import("wire/required_engines.zig");
const Store = store_core.Store;
const command_domain = @import("domain/command.zig");
const historical_domain = @import("domain/historical.zig");
const replay_binding = @import("../replay_binding.zig");
const model_settlement_domain = @import("domain/model_settlement.zig");
const AttemptBinding = store_core.AttemptBinding;
const OutputItemKind = historical_domain.OutputItemKind;
const ValidatedOutput = model_settlement_domain.ValidatedOutput;

pub const OutputMetadataWriter = output_format.OutputMetadataWriter;

pub const TestingPage = struct {
    page: historical_domain.RequestPage,
    store: *Store,

    const RequestPage = historical_domain.RequestPage;

    pub fn open(self: *TestingPage, store: *Store, binding: AttemptBinding) void {
        self.store = store;
        self.page.open(binding);
    }

    pub fn pageFor(self: *TestingPage, store: *Store) *RequestPage {
        self.store = store;
        return &self.page;
    }

    fn answer(self: *TestingPage, err: anytype) !void {
        if (err != error.PageRead) return err;
        return self.store.readRequestPage(&self.page);
    }

    pub fn settings(self: *TestingPage, out: *historical_domain.HistoricalSettings) !void {
        while (true) return self.page.settings(out) catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn validateOutputsStep(self: *TestingPage) !bool {
        while (true) return self.page.validateOutputsStep() catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn coverage(self: *TestingPage) !RequestPage.Coverage {
        while (!try self.validateOutputsStep()) {}
        while (true) return self.page.coverage() catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn nextEntryStep(self: *TestingPage, after_position: u64, bytes_left: *usize, items_left: *usize) !RequestPage.EntryProgress {
        const bytes = bytes_left.*;
        const items = items_left.*;
        while (true) return self.page.nextEntryStep(after_position, bytes_left, items_left) catch |err| {
            try self.answer(err);
            bytes_left.* = bytes;
            items_left.* = items;
            continue;
        };
    }

    pub fn nextEntry(self: *TestingPage, after_position: u64) !?historical_domain.HistoricalEntry {
        while (!try self.validateOutputsStep()) {}
        while (true) {
            var bytes: usize = 64 * 1024;
            var items: usize = 1024;
            switch (try self.nextEntryStep(after_position, &bytes, &items)) {
                .pending => {},
                .ready => |entry| return if (entry) |value| value.* else null,
            }
        }
    }

    pub fn nextDeclaredTool(self: *TestingPage, declaration: *historical_domain.Declaration, out: *historical_domain.HistoricalTool) !bool {
        while (true) return self.page.nextDeclaredTool(declaration, out) catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn nextProviderTool(self: *TestingPage, out: *historical_domain.HistoricalTool) !bool {
        while (true) return self.page.nextProviderTool(out) catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn nextTool(self: *TestingPage, out: *historical_domain.HistoricalTool) !bool {
        while (true) return self.page.nextTool(out) catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn prefixSeal(self: *TestingPage) !?historical_domain.PrefixSeal {
        while (true) return self.page.prefixSeal() catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn recordPrefixSeal(self: *TestingPage, seal: *const historical_domain.PrefixSeal) !void {
        while (true) return self.page.recordPrefixSeal(seal) catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn openOutput(self: *TestingPage, position: u64) !historical_domain.HistoricalOutput {
        while (true) return self.page.openOutput(position) catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn replayOutput(self: *TestingPage, entry: *const historical_domain.HistoricalEntry, request: replay_binding.Binding) !?historical_domain.HistoricalOutput {
        while (true) return self.page.replayOutput(entry, request) catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn nextOutputPart(self: *TestingPage) !?historical_domain.HistoricalPart {
        while (true) return self.page.nextOutputPart() catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn nextMessagePart(self: *TestingPage) !?historical_domain.HistoricalInputPart {
        while (true) return self.page.nextMessagePart() catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn nextToolResult(self: *TestingPage) !?historical_domain.HistoricalToolResult {
        while (true) return self.page.nextToolResult() catch |err| {
            try self.answer(err);
            continue;
        };
    }

    pub fn openContent(self: *TestingPage, reference: historical_domain.HistoricalContent, out: *TestingReader) !void {
        out.store = self.store;
        return self.page.openContent(reference, &out.reader);
    }

    pub fn expectTools(self: *TestingPage, ahead: RequestPage.ToolsAhead) void {
        self.page.expectTools(ahead);
    }

    pub fn currentDeclaration(self: *const TestingPage) historical_domain.Declaration {
        return self.page.currentDeclaration();
    }

    pub fn admissionPosition(self: *const TestingPage) u64 {
        return self.page.admissionPosition();
    }

    pub fn toolGroupCursor(self: *const TestingPage) u64 {
        return self.page.toolGroupCursor();
    }

    pub fn resumeToolGroups(self: *TestingPage, cursor: u64) void {
        self.page.resumeToolGroups(cursor);
    }

    pub fn resumeKeys(self: *const TestingPage) historical_domain.Keys {
        return self.page.resumeKeys();
    }

    pub fn outstandingReaders(self: *const TestingPage) usize {
        return self.page.outstandingReaders();
    }

    pub fn isActive(self: *const TestingPage) bool {
        return self.page.isActive();
    }

    pub fn ownsContent(self: *TestingPage, content: historical_domain.HistoricalContent) bool {
        return self.page.ownsContent(content);
    }

    pub fn bindingMatches(self: *const TestingPage, expected: AttemptBinding) bool {
        return self.page.bindingMatches(expected);
    }

    pub fn ownsSettings(self: *TestingPage, frozen: *const historical_domain.HistoricalSettings) bool {
        return self.page.ownsSettings(frozen);
    }

    pub fn close(self: *TestingPage) void {
        self.page.close();
    }
};

pub const TestingReader = struct {
    reader: historical_domain.HistoricalReader,
    store: *Store,

    pub fn read(self: *TestingReader, start: u64, destination: []u8) !usize {
        while (true) return self.reader.read(start, destination) catch |err| {
            if (err != error.PageRead) return err;
            try self.store.readRequestPage(self.reader.view);
            continue;
        };
    }

    pub fn usable(self: *const TestingReader) bool {
        return self.reader.usable();
    }

    pub fn ownedBy(self: *const TestingReader, page: *TestingPage) bool {
        return self.reader.ownedBy(&page.page);
    }

    pub fn close(self: *TestingReader) void {
        self.reader.close();
    }
};
pub const offeredSetSql = @import("domain/tool_set.zig").offeredSetSql;

pub fn hostToolRecordsWith(comptime extra: []const tool_defs.Record) [tool_defs.built_in_tool_set.records.len + extra.len]tool_defs.Record {
    var records: [tool_defs.built_in_tool_set.records.len + extra.len]tool_defs.Record = undefined;
    @memcpy(records[0..tool_defs.built_in_tool_set.records.len], tool_defs.built_in_tool_set.records);
    @memcpy(records[tool_defs.built_in_tool_set.records.len..], extra);
    sortHostToolRecords(&records);
    return records;
}

pub fn sortHostToolRecords(records: []tool_defs.Record) void {
    std.mem.sort(tool_defs.Record, records, {}, struct {
        fn lessThan(_: void, left: tool_defs.Record, right: tool_defs.Record) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
}

pub fn testingStoreToolSet(storage: *Store, tmp: *std.testing.TmpDir, io: std.Io, host_tool_set: ?*const tool_defs.HostToolSet) !void {
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    return storage.openTarget(io, .{ .sqlite = database }, root, .{ .host_tool_set = host_tool_set });
}

pub fn testingSqliteStore(storage: *Store, tmp: *std.testing.TmpDir, io: std.Io) !void {
    return openSqlite(storage, tmp, io, .{});
}

fn openSqlite(storage: *Store, tmp: *std.testing.TmpDir, io: std.Io, options: TestingStoreOptions) !void {
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    const selector = options.identity orelse root;
    const default = options.host_tool_set == &tool_defs.built_in_tool_set and
        std.meta.eql(options.served, (TestingStoreOptions{}).served);
    if (default) if (tmp.dir.statFile(io, "store.sqlite3", .{})) |_| {} else |err| switch (err) {
        error.FileNotFound => try copyTemplate(tmp, io, database, selector),
        else => return err,
    };
    var mismatch: @import("schema.zig").IdentityMismatch = .{};
    return storage.openTarget(io, .{ .sqlite = database }, selector, .{ .served = options.served, .host_tool_set = options.host_tool_set, .identity_mismatch = &mismatch }) catch |err| {
        std.debug.print("testing Store open failed: {s}, selector={s}, saved={s}\n", .{ @errorName(err), selector, mismatch.saved_selector.slice() });
        return err;
    };
}

const Template = struct {
    var state = std.atomic.Value(u8).init(0);
    var bytes: []const u8 = &.{};

    fn get(io: std.Io) ![]const u8 {
        while (true) switch (state.cmpxchgStrong(0, 1, .acquire, .acquire) orelse 0) {
            0 => break,
            1 => std.atomic.spinLoopHint(),
            else => return bytes,
        };
        errdefer state.store(0, .release);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
        var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
        var storage: Store = undefined;
        try storage.open(io, try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root}), root);
        try storage.close();
        bytes = try tmp.dir.readFileAlloc(io, "store.sqlite3", std.heap.page_allocator, .unlimited);
        state.store(2, .release);
        return bytes;
    }
};

fn copyTemplate(tmp: *std.testing.TmpDir, io: std.Io, database: []const u8, selector: []const u8) !void {
    try tmp.dir.writeFile(io, .{ .sub_path = "store.sqlite3", .data = try Template.get(io) });
    var path_buffer: [platform.max_database_path_bytes + 1]u8 = undefined;
    const path = (try std.fmt.bufPrint(&path_buffer, "{s}\x00", .{database}))[0..database.len :0];
    var connection: ?*sqlite.c.sqlite3 = null;
    defer _ = sqlite.c.sqlite3_close(connection);
    if (sqlite.c.sqlite3_open_v2(path, &connection, sqlite.c.SQLITE_OPEN_READWRITE, null) != sqlite.c.SQLITE_OK)
        return error.SqliteOpenFailed;
    const statement = try sqlite.prepare(connection.?, "UPDATE store_meta SET meta_value=CASE meta_key " ++
        "WHEN 'store_selector' THEN ?1 ELSE lower(hex(randomblob(16))) END WHERE meta_key IN ('store_selector','store_id')");
    defer _ = sqlite.c.sqlite3_finalize(statement);
    try sqlite.bindText(statement, 1, selector);
    if (sqlite.c.sqlite3_step(statement) != sqlite.c.SQLITE_DONE or sqlite.c.sqlite3_changes(connection) != 2)
        return error.SqliteExecFailed;
}

pub const Engine = enum { sqlite, mysql };

pub const Case = struct {
    engine: Engine,
    rerun: bool = false,
};

pub const ReadWork = struct {
    storage: *Store = undefined,
    engine: Engine = undefined,
    before: u64 = 0,
    steps: u64 = 0,

    pub fn begin(self: *ReadWork, case: *const Case, storage: *Store) !void {
        self.* = .{ .storage = storage, .engine = case.engine };
        switch (self.engine) {
            .sqlite => sqlite.c.sqlite3_progress_handler(storage.sqliteDatabase(), 1, progress, self),
            .mysql => self.before = try mysql_testing.handlerReads(storage),
        }
    }

    pub fn finish(self: *ReadWork) !u64 {
        return switch (self.engine) {
            .sqlite => blk: {
                self.cancel();
                break :blk self.steps;
            },
            .mysql => (try mysql_testing.handlerReads(self.storage)) - self.before,
        };
    }

    pub fn cancel(self: *ReadWork) void {
        if (self.engine == .sqlite) sqlite.c.sqlite3_progress_handler(self.storage.sqliteDatabase(), 0, null, null);
    }

    fn progress(context: ?*anyopaque) callconv(.c) c_int {
        const self: *ReadWork = @ptrCast(@alignCast(context.?));
        self.steps += 1;
        return 0;
    }
};

pub const EngineName = required_engines.EngineName;
pub const parseRequiredEngines = required_engines.parse;

pub fn requiredEngines() !std.EnumSet(EngineName) {
    const Parsed = struct {
        var names: ?std.EnumSet(EngineName) = null;
    };
    if (Parsed.names) |names| return names;
    var environ = try std.testing.environ.createMap(std.testing.allocator);
    defer environ.deinit();
    const names = try required_engines.fromEnviron(&environ);
    Parsed.names = names;
    return names;
}

pub const checked_elsewhere: std.EnumSet(EngineName) = .initMany(&.{.postgres});

pub fn unbuiltEngine(names: std.EnumSet(EngineName), elsewhere: std.EnumSet(EngineName)) ?EngineName {
    var listed = names.iterator();
    while (listed.next()) |name| {
        if (elsewhere.contains(name)) continue;
        if (std.meta.stringToEnum(Engine, @tagName(name)) == null) return name;
    }
    return null;
}

pub fn forEachEngine(comptime run: anytype) !void {
    if (unbuiltEngine(try requiredEngines(), checked_elsewhere)) |name| {
        std.debug.print("RUI_TEST_REQUIRE_ENGINES lists {s}, an engine not built into these tests\n", .{@tagName(name)});
        return error.RequiredEngineNotBuilt;
    }
    inline for (comptime std.enums.values(Engine)) |engine| {
        if (engine != .mysql or try mysql_testing.available()) {
            var case: Case = .{ .engine = engine };
            run(&case) catch |err| {
                std.debug.print("conformance test failed on engine {s}\n", .{@tagName(engine)});
                return err;
            };
            if (engine == .mysql) {
                mysql_dialect_check.conformancePassed();
                case.rerun = true;
                run(&case) catch |err| {
                    std.debug.print("conformance test failed on engine mysql, every write run twice\n", .{});
                    return err;
                };
            }
        }
    }
}

pub fn testingStore(case: *const Case, storage: *Store, tmp: *std.testing.TmpDir, io: std.Io) !void {
    return testingStoreWith(case, storage, tmp, io, .{});
}

pub const TestingStoreOptions = struct {
    host_tool_set: *const tool_defs.HostToolSet = &tool_defs.built_in_tool_set,
    identity: ?[]const u8 = null,
    served: protocol.Routes = protocol.routesAll(.endpoint),
};

pub fn testingStoreWith(case: *const Case, storage: *Store, tmp: *std.testing.TmpDir, io: std.Io, options: TestingStoreOptions) !void {
    switch (case.engine) {
        .mysql => {
            try mysql_testing.open(storage, tmp, io, options);
            storage.engine.mysql.state.testing_drop_armed = case.rerun;
        },
        .sqlite => return openSqlite(storage, tmp, io, options),
    }
}

pub fn stageEndingMessageUpgrade(storage: *Store, keep_pending_forward: bool) !void {
    const schema = @import("schema.zig");
    const Native = struct {
        fn exec(store: *Store, sql: [:0]const u8) !void {
            if (store.engine == .mysql) return mysql_testing.rawExec(store, sql);
            return sqlite.exec(store.sqliteDatabase(), sql);
        }
    };
    const from: u32 = 66;
    try dropPinOrganization(storage);
    try dropObligationFrontier(storage);
    const old_model = comptime blk: {
        for (schema.migrations[(from - 1) - schema.migration_baseline].sqlite) |sql| {
            if (std.mem.startsWith(u8, sql, "CREATE TABLE model_operation(")) break :blk sql;
        }
        @compileError("the ending upgrade fixture requires format 66's Operation CREATE");
    };
    const columns = comptime blk: {
        for (schema.tables) |table| {
            if (std.mem.eql(u8, table.name, "model_operation")) break :blk table.columns;
        }
        unreachable;
    };
    inline for (0..columns.len) |index| {
        const column = columns[columns.len - 1 - index];
        const added = comptime blk: {
            @setEvalBranchQuota(100 * old_model.len);
            break :blk std.mem.indexOf(u8, old_model, "\n " ++ column.name ++ " ") == null;
        };
        // dropPinOrganization already undid format 91's output_limit (dropFormat91OutputLimit).
        if (added and comptime !std.mem.eql(u8, column.name, "output_limit")) try Native.exec(storage, "ALTER TABLE model_operation DROP COLUMN " ++ column.name);
    }
    const old = schema.migrations[53 - schema.migration_baseline];
    const suppress = schema.migrations[56 - schema.migration_baseline];
    for (if (storage.engine == .mysql) old.mysql else old.sqlite) |sql| {
        if (std.mem.startsWith(u8, sql, "CREATE TABLE session_ending_owed(")) try Native.exec(storage, sql);
    }
    if (storage.engine == .mysql) {
        for (suppress.mysql) |sql| {
            if (std.mem.startsWith(u8, sql, "ALTER TABLE session_ending_owed ")) try Native.exec(storage, sql);
        }
    } else {
        for (suppress.sqlite) |sql| {
            if (std.mem.indexOf(u8, sql, "session_ending_owed") != null or std.mem.startsWith(u8, sql, "CREATE INDEX session_ending_open ")) try Native.exec(storage, sql);
        }
    }
    try Native.exec(storage, "INSERT INTO session_ending_owed(turn_id,delivered,suppress_message) SELECT source_id,message_delivered,suppress_message FROM session_forward WHERE message_delivered IS NOT NULL");
    if (!keep_pending_forward) try Native.exec(storage, "DELETE FROM session_forward WHERE message_delivered=0");
    if (storage.engine == .mysql) {
        try Native.exec(storage, "ALTER TABLE session_forward DROP INDEX session_forward_message, DROP CHECK session_forward_chk_7, DROP CHECK session_forward_chk_8, DROP COLUMN message_delivered, DROP COLUMN suppress_message");
    } else {
        try Native.exec(storage, "ALTER TABLE session_forward RENAME TO upgrade_forward");
        for (old.sqlite) |sql| {
            if (std.mem.startsWith(u8, sql, "CREATE TABLE session_forward(")) try Native.exec(storage, sql);
        }
        try Native.exec(storage, "INSERT INTO session_forward(forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at) SELECT forward_id,target_ref,child_ref,kind,source_id,position,ordinal,delivered_at FROM upgrade_forward");
        try Native.exec(storage, "DROP TABLE upgrade_forward");
        for (old.sqlite) |sql| {
            if (std.mem.startsWith(u8, sql, "CREATE INDEX session_forward_")) try Native.exec(storage, sql);
        }
        try Native.exec(storage, comptime std.fmt.comptimePrint("PRAGMA user_version={d}", .{from}));
    }
    try Native.exec(storage, comptime std.fmt.comptimePrint("UPDATE store_meta SET meta_value='{d}' WHERE meta_key='format'", .{from}));
    if (storage.engine == .mysql) {
        for (schema.migrations[from - schema.migration_baseline ..]) |step| {
            for (step.mysql) |sql| try Native.exec(storage, sql);
        }
        try Native.exec(storage, comptime std.fmt.comptimePrint("UPDATE store_meta SET meta_value='{d}' WHERE meta_key='format'", .{schema.schema_version}));
    }
}

fn dropCompoundContentUpgradeShape(storage: *Store) !void {
    const Native = struct {
        fn exec(store: *Store, sql: [:0]const u8) !void {
            if (store.engine == .mysql) return mysql_testing.rawExec(store, sql);
            return sqlite.exec(store.sqliteDatabase(), sql);
        }
    };
    try Native.exec(storage, "UPDATE core_command SET primary_content_id=secondary_content_id,secondary_content_id=NULL WHERE kind=2 AND accepted=0");
    try Native.exec(storage, "DROP TABLE content_part");
    if (storage.engine == .mysql) {
        try Native.exec(storage, "SET @rui_parts_ddl=(SELECT CONCAT('ALTER TABLE content DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`') FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='content' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('form',cc.CHECK_CLAUSE)>0)");
        try Native.exec(storage, "PREPARE rui_parts FROM @rui_parts_ddl");
        try Native.exec(storage, "EXECUTE rui_parts");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_parts");
        try Native.exec(storage, "SET @rui_parts_ddl=NULL");
    }
    try Native.exec(storage, "ALTER TABLE content DROP COLUMN form");
}

fn dropFinalInputUpgradeShape(storage: *Store) !void {
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM action_value", .{}));
    if (storage.engine == .mysql) {
        try mysql_testing.rawExec(storage, "DROP TABLE action_value");
    } else {
        try sqlite.exec(storage.sqliteDatabase(), "DROP TABLE action_value");
    }
    try dropCompoundContentUpgradeShape(storage);
    @setEvalBranchQuota(200_000);
    const Native = struct {
        fn exec(store: *Store, sql: [:0]const u8) !void {
            if (store.engine == .mysql) return mysql_testing.rawExec(store, sql);
            return sqlite.exec(store.sqliteDatabase(), sql);
        }
    };
    if (storage.engine == .mysql) {
        const child_fk = " FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='conversation_entry' AND COLUMN_NAME='source_kind' AND REFERENCED_TABLE_NAME='message_admission'";
        try Native.exec(storage, "SET @rui_input_ddl=(SELECT CONCAT('ALTER TABLE conversation_entry DROP FOREIGN KEY `',REPLACE(CONSTRAINT_NAME,'`','``'),'`')" ++ child_fk ++ ")");
        try Native.exec(storage, "PREPARE rui_input FROM @rui_input_ddl");
        try Native.exec(storage, "EXECUTE rui_input");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_input");
        try Native.exec(storage, "SET @rui_input_ddl=(SELECT CONCAT('ALTER TABLE conversation_entry DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`') FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='conversation_entry' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('source_kind',cc.CHECK_CLAUSE)>0)");
        try Native.exec(storage, "PREPARE rui_input FROM @rui_input_ddl");
        try Native.exec(storage, "EXECUTE rui_input");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_input");
        try Native.exec(storage, "ALTER TABLE conversation_entry DROP INDEX conversation_entry_activity_user, DROP INDEX conversation_entry_activity_assistant");
        try Native.exec(storage, "SET @rui_input_ddl=(SELECT CONCAT('ALTER TABLE conversation_entry DROP INDEX `',REPLACE(INDEX_NAME,'`','``'),'`') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='conversation_entry' GROUP BY INDEX_NAME HAVING GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)='source_admission_id,source_kind')");
        try Native.exec(storage, "PREPARE rui_input FROM @rui_input_ddl");
        try Native.exec(storage, "EXECUTE rui_input");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_input");
        try Native.exec(storage, "ALTER TABLE conversation_entry DROP COLUMN source_kind");
        try Native.exec(storage, "ALTER TABLE message_admission DROP INDEX message_admission_activity");
        try Native.exec(storage, "SET @rui_input_ddl=(SELECT CONCAT('ALTER TABLE message_admission DROP INDEX `',REPLACE(INDEX_NAME,'`','``'),'`') FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='message_admission' AND NON_UNIQUE=0 GROUP BY INDEX_NAME HAVING GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)='admission_id,source_kind')");
        try Native.exec(storage, "PREPARE rui_input FROM @rui_input_ddl");
        try Native.exec(storage, "EXECUTE rui_input");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_input");
        try Native.exec(storage, "SET @rui_input_ddl=NULL");
    } else {
        try Native.exec(storage, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        defer Native.exec(storage, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF") catch unreachable;
        try Native.exec(storage, "ALTER TABLE conversation_entry RENAME TO upgrade_conversation_entry");
        try Native.exec(storage, @import("schema.zig").migrations[59 - @import("schema.zig").migration_baseline].sqlite[2]);
        try Native.exec(storage, "INSERT INTO conversation_entry(session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_skill_admission_id,source_skill_position,source_operation_id,source_item_ordinal,content_id,recorded_at) SELECT session_ref,entry_ordinal,session_position,entry_kind,turn_id,source_admission_id,source_revision,source_catalog_position,source_skill_admission_id,source_skill_position,source_operation_id,source_item_ordinal,content_id,recorded_at FROM upgrade_conversation_entry");
        try Native.exec(storage, "DROP TABLE upgrade_conversation_entry");
        try Native.exec(storage, "CREATE INDEX conversation_entry_history ON conversation_entry(session_ref,session_position)");
        try std.testing.expectEqual(@as(u64, 0), try sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM pragma_foreign_key_check", .{}));
    }
    if (storage.engine == .mysql) {
        try Native.exec(storage, "ALTER TABLE message_admission MODIFY COLUMN message_admission_person_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN sender_session_ref IS NULL THEN session_ref END) STORED");
        const kind_checks = " FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='message_admission' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('source_kind',cc.CHECK_CLAUSE)>0 LIMIT 1";
        for (0..2) |_| {
            try Native.exec(storage, "SET @rui_final_ddl=(SELECT CONCAT('ALTER TABLE message_admission DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`')" ++ kind_checks ++ ")");
            try Native.exec(storage, "PREPARE rui_final FROM @rui_final_ddl");
            try Native.exec(storage, "EXECUTE rui_final");
            try Native.exec(storage, "DEALLOCATE PREPARE rui_final");
        }
        try Native.exec(storage, "ALTER TABLE message_admission DROP COLUMN source_kind");
        const checks = " FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='message_admission' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('source_action_id',cc.CHECK_CLAUSE)>0";
        try Native.exec(storage, "SET @rui_final_ddl=(SELECT CONCAT('ALTER TABLE message_admission DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`')" ++ checks ++ ")");
        try Native.exec(storage, "PREPARE rui_final FROM @rui_final_ddl");
        try Native.exec(storage, "EXECUTE rui_final");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_final");
        try Native.exec(storage, "SET @rui_final_ddl=(SELECT CONCAT('ALTER TABLE message_admission DROP FOREIGN KEY `',REPLACE(CONSTRAINT_NAME,'`','``'),'`') FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='message_admission' AND COLUMN_NAME='source_action_id' AND REFERENCED_TABLE_NAME='action_operation')");
        try Native.exec(storage, "PREPARE rui_final FROM @rui_final_ddl");
        try Native.exec(storage, "EXECUTE rui_final");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_final");
        try Native.exec(storage, "SET @rui_final_ddl=NULL");
        try Native.exec(storage, "ALTER TABLE message_admission MODIFY COLUMN message_admission_person_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN sender_session_ref IS NULL THEN session_ref END) STORED, DROP COLUMN source_action_id");
    } else {
        try Native.exec(storage, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        defer Native.exec(storage, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF") catch unreachable;
        try Native.exec(storage, "ALTER TABLE message_admission RENAME TO upgrade_message_admission");
        comptime var statements = std.mem.splitScalar(u8, baseline_sqlite_ddl, ';');
        inline while (comptime statements.next()) |statement| {
            const sql = comptime std.mem.trim(u8, statement, " \n\r\t");
            if (comptime std.mem.startsWith(u8, sql, "CREATE TABLE message_admission(")) try Native.exec(storage, comptime std.fmt.comptimePrint("{s}", .{sql}));
        }
        try Native.exec(storage, "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at,sender_session_ref,sender_position) SELECT admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at,sender_session_ref,sender_position FROM upgrade_message_admission");
        try Native.exec(storage, "DROP TABLE upgrade_message_admission");
        comptime var indexes = std.mem.splitScalar(u8, baseline_sqlite_ddl, ';');
        inline while (comptime indexes.next()) |statement| {
            const sql = comptime std.mem.trim(u8, statement, " \n\r\t");
            if (comptime (std.mem.startsWith(u8, sql, "CREATE INDEX message_admission_") or std.mem.startsWith(u8, sql, "CREATE UNIQUE INDEX message_admission_"))) try Native.exec(storage, comptime std.fmt.comptimePrint("{s}", .{sql}));
        }
        try std.testing.expectEqual(@as(u64, 0), try sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM pragma_foreign_key_check", .{}));
    }
}

fn dropBackgroundUpgradeShape(storage: *Store) !void {
    const schema = @import("schema.zig");
    const Native = struct {
        fn exec(store: *Store, sql: [:0]const u8) !void {
            if (store.engine == .mysql) return mysql_testing.rawExec(store, sql);
            return sqlite.exec(store.sqliteDatabase(), sql);
        }
    };
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM core_command WHERE kind>=7", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM session_pin_command", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM session_pin WHERE command_key IS NOT NULL", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM action_control_command", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM action_stop", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM action_stop_command", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM action_operation WHERE background_content_id IS NOT NULL OR background_position IS NOT NULL OR background_at IS NOT NULL", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM session_stop WHERE action_cutoff<>0", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM message_admission WHERE source_action_id IS NOT NULL", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM message_admission WHERE source_kind NOT IN (1,2)", .{}));
    // Reject unrepresentable compound values before any dialect starts DDL.
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM content WHERE form<>0", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(storage, "SELECT count(*) FROM content_part", .{}));
    const catalog = " FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.CONSTRAINT_TYPE='CHECK' AND tc.TABLE_NAME=";
    const checks = .{
        .{ "action_operation", "LOCATE('background_',cc.CHECK_CLAUSE)>0", 2 },
        .{ "session_stop", "LOCATE('action_cutoff',cc.CHECK_CLAUSE)>0", 1 },
    };
    const background_fk = " FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='action_operation' AND COLUMN_NAME='background_content_id' AND REFERENCED_TABLE_NAME='content' AND REFERENCED_COLUMN_NAME='content_id'";
    if (storage.engine == .mysql) {
        inline for (checks) |check| {
            try std.testing.expectEqual(@as(u64, check[2]), try mysql_testing.rawQueryU64(storage, "SELECT count(*) AS value" ++ catalog ++ "'" ++ check[0] ++ "' AND " ++ check[1]));
        }
        try std.testing.expectEqual(@as(u64, 1), try mysql_testing.rawQueryU64(storage, "SELECT count(*) AS value" ++ background_fk));
        try std.testing.expectEqual(@as(u64, 1), try mysql_testing.rawQueryU64(storage, "SELECT count(*) AS value" ++ catalog ++ "'core_command' AND LOWER(TRIM(REPLACE(REPLACE(REPLACE(cc.CHECK_CLAUSE,'`',''),'(',''),')','')))='kind between 1 and 9'"));
        inline for (checks) |check| {
            try Native.exec(storage, "SET @rui_rewind_ddl=(SELECT CONCAT('ALTER TABLE " ++ check[0] ++ " ',GROUP_CONCAT(CONCAT('DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`') ORDER BY tc.CONSTRAINT_NAME SEPARATOR ', '))" ++ catalog ++ "'" ++ check[0] ++ "' AND " ++ check[1] ++ ")");
            try Native.exec(storage, "PREPARE rui_rewind FROM @rui_rewind_ddl");
            try Native.exec(storage, "EXECUTE rui_rewind");
            try Native.exec(storage, "DEALLOCATE PREPARE rui_rewind");
        }
        try Native.exec(storage, "SET @rui_rewind_ddl=(SELECT CONCAT('ALTER TABLE action_operation DROP FOREIGN KEY `',REPLACE(CONSTRAINT_NAME,'`','``'),'`')" ++ background_fk ++ ")");
        try Native.exec(storage, "PREPARE rui_rewind FROM @rui_rewind_ddl");
        try Native.exec(storage, "EXECUTE rui_rewind");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_rewind");
        try Native.exec(storage, "SET @rui_rewind_ddl=NULL");
    }
    try Native.exec(storage, "DROP TABLE action_stop_command");
    try Native.exec(storage, "DROP TABLE action_stop");
    try dropFinalInputUpgradeShape(storage);
    try Native.exec(storage, "DROP TABLE action_control_command");
    if (storage.engine == .mysql) {
        try Native.exec(storage, "ALTER TABLE action_operation DROP INDEX action_operation_background, DROP INDEX action_operation_background_results, DROP INDEX action_operation_background_ready, DROP INDEX action_operation_awaiting, DROP COLUMN action_operation_background_results_lead, DROP COLUMN action_operation_background_ready_lead, DROP COLUMN action_operation_awaiting_lead");
        try Native.exec(storage, "ALTER TABLE action_operation DROP INDEX action_operation_session_results, MODIFY action_operation_session_results_lead VARCHAR(6) GENERATED ALWAYS AS (CASE WHEN acceptance_position IS NOT NULL THEN session_ref END) STORED, ADD INDEX action_operation_session_results(action_operation_session_results_lead,parent_operation_id,acceptance_position)");
        try Native.exec(storage, "ALTER TABLE action_operation DROP COLUMN background_at, DROP COLUMN background_position, DROP COLUMN background_content_id");
        try Native.exec(storage, "ALTER TABLE session_stop DROP COLUMN action_cutoff");
    } else {
        inline for (.{ "action_operation_background", "action_operation_background_results", "action_operation_background_ready", "action_operation_awaiting", "action_operation_session_results" }) |name| {
            try Native.exec(storage, "DROP INDEX " ++ name);
        }
        try Native.exec(storage, "ALTER TABLE action_operation DROP COLUMN background_at");
        try Native.exec(storage, "ALTER TABLE action_operation DROP COLUMN background_position");
        try Native.exec(storage, "ALTER TABLE action_operation DROP COLUMN background_content_id");
        const result_index = comptime blk: {
            @setEvalBranchQuota(200_000);
            var statements = std.mem.splitScalar(u8, baseline_sqlite_ddl, ';');
            while (statements.next()) |statement| {
                const text = std.mem.trim(u8, statement, " \n\r\t");
                if (std.mem.startsWith(u8, text, "CREATE INDEX action_operation_session_results ")) break :blk std.fmt.comptimePrint("{s}", .{text});
            }
            @compileError("the upgrade fixture requires the baseline Action result index");
        };
        try Native.exec(storage, result_index);
        try Native.exec(storage, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        defer Native.exec(storage, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF") catch unreachable;
        try Native.exec(storage, "ALTER TABLE session_stop RENAME TO upgrade_session_stop");
        for (schema.migrations[56 - schema.migration_baseline].sqlite) |sql| {
            if (std.mem.startsWith(u8, sql, "CREATE TABLE session_stop(")) try Native.exec(storage, sql);
        }
        try Native.exec(storage, "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused) SELECT command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused FROM upgrade_session_stop");
        try Native.exec(storage, "DROP TABLE upgrade_session_stop");
        for (schema.migrations[56 - schema.migration_baseline].sqlite) |sql| {
            if (std.mem.startsWith(u8, sql, "CREATE INDEX session_stop_")) try Native.exec(storage, sql);
        }
        try std.testing.expectEqual(@as(u64, 0), try sqliteQueryU64(storage.sqliteDatabase(), "SELECT count(*) FROM pragma_foreign_key_check", .{}));
    }
}

fn dropPinOrganization(storage: *Store) !void {
    try dropFormat87Indexes(storage);
    try restoreSessionArchiveForTesting(storage);
    const schema = @import("schema.zig");
    const Native = struct {
        fn exec(store: *Store, sql: [:0]const u8) !void {
            if (store.engine == .mysql) return mysql_testing.rawExec(store, sql);
            return sqlite.exec(store.sqliteDatabase(), sql);
        }
    };
    try dropBackgroundUpgradeShape(storage);
    // After dropBackgroundUpgradeShape's refusals, so a refused rewind leaves a usable Store.
    try dropMysqlInPlaceColumns(storage);
    try dropFormat91OutputLimit(storage);
    if (storage.engine == .mysql) {
        try Native.exec(storage, "SET @rui_creator_ddl=(SELECT CONCAT('ALTER TABLE session DROP FOREIGN KEY `',REPLACE(CONSTRAINT_NAME,'`','``'),'`') FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='session' AND COLUMN_NAME='creator_ref' AND REFERENCED_TABLE_NAME='session')");
        try Native.exec(storage, "PREPARE rui_creator FROM @rui_creator_ddl");
        try Native.exec(storage, "EXECUTE rui_creator");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_creator");
        try Native.exec(storage, "SET @rui_creator_ddl=(SELECT CONCAT('ALTER TABLE session DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`') FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='session' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('creator_ref',cc.CHECK_CLAUSE)>0)");
        try Native.exec(storage, "PREPARE rui_creator FROM @rui_creator_ddl");
        try Native.exec(storage, "EXECUTE rui_creator");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_creator");
        try Native.exec(storage, "SET @rui_creator_ddl=NULL");
    }
    // Format 84's creator index covers creator_ref, so it goes before the column.
    try Native.exec(storage, if (storage.engine == .mysql) "DROP INDEX session_creator ON session" else "DROP INDEX session_creator");
    try Native.exec(storage, "ALTER TABLE session DROP COLUMN creator_ref");
    try Native.exec(storage, "DROP TABLE session_pin");
    try Native.exec(storage, "DROP TABLE session_pin_command");
    if (storage.engine == .mysql) {
        try Native.exec(storage, "SET @rui_pin_kind_ddl=NULL");
        try Native.exec(storage, "SET @rui_pin_kind_ddl=(SELECT CONCAT('ALTER TABLE core_command DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`, ADD CHECK(kind BETWEEN 1 AND 6)') FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='core_command' AND tc.CONSTRAINT_TYPE='CHECK' AND LOWER(TRIM(REPLACE(REPLACE(REPLACE(cc.CHECK_CLAUSE,'`',''),'(',''),')','')))='kind between 1 and 9')");
        try Native.exec(storage, "PREPARE rui_pin_kind FROM @rui_pin_kind_ddl");
        try Native.exec(storage, "EXECUTE rui_pin_kind");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_pin_kind");
        try Native.exec(storage, "SET @rui_pin_kind_ddl=NULL");
    } else {
        try Native.exec(storage, "PRAGMA foreign_keys=OFF;PRAGMA legacy_alter_table=ON");
        defer Native.exec(storage, "PRAGMA foreign_keys=ON;PRAGMA legacy_alter_table=OFF") catch unreachable;
        const step = schema.migrations[74 - schema.migration_baseline];
        try Native.exec(storage, step.sqlite[0]);
        try Native.exec(storage, schema.migrations[56 - schema.migration_baseline].sqlite[1]);
        for (step.sqlite[2..5]) |sql| try Native.exec(storage, sql);
    }
}

/// Undoes formats 89 and 90 on MySQL, whose steps add core_command.missing_settings and
/// tool_record.remote_name in place, so a Store rewound below them replays ADD COLUMN on a table that
/// has it. Newest first. SQLite's steps rebuild tables from named columns, so they replay unchanged.
fn dropMysqlInPlaceColumns(storage: *Store) !void {
    if (storage.engine != .mysql) return;
    try mysql_testing.rawExec(storage, "SET @rui_remote_ddl=(SELECT CONCAT('ALTER TABLE tool_record DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`') FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='tool_record' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('remote_name',cc.CHECK_CLAUSE)>0)");
    try mysql_testing.rawExec(storage, "PREPARE rui_remote FROM @rui_remote_ddl");
    try mysql_testing.rawExec(storage, "EXECUTE rui_remote");
    try mysql_testing.rawExec(storage, "DEALLOCATE PREPARE rui_remote");
    try mysql_testing.rawExec(storage, "SET @rui_remote_ddl=NULL");
    try mysql_testing.rawExec(storage, "ALTER TABLE tool_record DROP COLUMN remote_name");
    try mysql_testing.rawExec(storage, "SET @rui_missing_ddl=(SELECT CONCAT('ALTER TABLE core_command DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`') FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='core_command' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('missing_settings',cc.CHECK_CLAUSE)>0)");
    try mysql_testing.rawExec(storage, "PREPARE rui_missing FROM @rui_missing_ddl");
    try mysql_testing.rawExec(storage, "EXECUTE rui_missing");
    try mysql_testing.rawExec(storage, "DEALLOCATE PREPARE rui_missing");
    try mysql_testing.rawExec(storage, "SET @rui_missing_ddl=NULL");
    try mysql_testing.rawExec(storage, "ALTER TABLE core_command DROP COLUMN missing_settings");
}

/// Undoes format 91's output limits. SQLite's step rebuilds model_fact from named columns, so only
/// model_operation's added column goes; MySQL adds both columns with table CHECKs, which go first.
fn dropFormat91OutputLimit(storage: *Store) !void {
    if (storage.engine != .mysql) return sqlite.exec(storage.sqliteDatabase(), "ALTER TABLE model_operation DROP COLUMN output_limit");
    inline for (.{ "model_fact", "model_operation" }) |table| {
        try mysql_testing.rawExec(storage, "SET @rui_output_ddl=(SELECT CONCAT('ALTER TABLE " ++ table ++ " DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`') FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='" ++ table ++ "' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('output_limit',cc.CHECK_CLAUSE)>0)");
        try mysql_testing.rawExec(storage, "PREPARE rui_output FROM @rui_output_ddl");
        try mysql_testing.rawExec(storage, "EXECUTE rui_output");
        try mysql_testing.rawExec(storage, "DEALLOCATE PREPARE rui_output");
        try mysql_testing.rawExec(storage, "SET @rui_output_ddl=NULL");
        try mysql_testing.rawExec(storage, "ALTER TABLE " ++ table ++ " DROP COLUMN output_limit");
    }
}

/// Undoes format 87's partial indexes (on MySQL, their `_lead` generated columns too). Every helper that
/// rewinds a Store below format 87 runs this first, through dropPinOrganization.
fn dropFormat87Indexes(storage: *Store) !void {
    if (storage.engine == .mysql) {
        try mysql_testing.rawExec(storage, "ALTER TABLE action_operation DROP INDEX action_operation_unaccepted, DROP COLUMN action_operation_unaccepted_lead");
        return mysql_testing.rawExec(storage, "ALTER TABLE turn DROP INDEX turn_outcome_unpositioned, DROP COLUMN turn_outcome_unpositioned_lead");
    }
    try sqlite.exec(storage.sqliteDatabase(), "DROP INDEX action_operation_unaccepted");
    return sqlite.exec(storage.sqliteDatabase(), "DROP INDEX turn_outcome_unpositioned");
}

/// Format 85 has no session_archive table; archive membership lives in session.archive_seq.
/// A fixture downgraded below format 84 needs the pre-85 table back, filled from that column.
fn restoreSessionArchiveForTesting(storage: *Store) !void {
    const schema = @import("schema.zig");
    const Native = struct {
        fn exec(store: *Store, sql: [:0]const u8) !void {
            if (store.engine == .mysql) return mysql_testing.rawExec(store, sql);
            return sqlite.exec(store.sqliteDatabase(), sql);
        }
    };
    const sqlite_create = comptime blk: {
        for (schema.migrations[56 - schema.migration_baseline].sqlite) |sql| {
            if (std.mem.startsWith(u8, sql, "CREATE TABLE session_archive(")) break :blk sql;
        }
        @compileError("the archive downgrade fixture requires format 57's session_archive CREATE");
    };
    const mysql_create = comptime blk: {
        for (schema.migrations[56 - schema.migration_baseline].mysql) |sql| {
            if (std.mem.startsWith(u8, sql, "CREATE TABLE session_archive(")) break :blk sql;
        }
        @compileError("the archive downgrade fixture requires format 57's session_archive CREATE");
    };
    const copy = "INSERT INTO session_archive(session_ref,command_key) SELECT s.session_ref,c.command_key FROM session s JOIN core_command c ON c.command_seq=s.archive_seq WHERE s.archive_seq IS NOT NULL";
    if (storage.engine == .mysql) {
        try Native.exec(storage, "SET @rui_archive_ddl=(SELECT CONCAT('ALTER TABLE session DROP FOREIGN KEY `',REPLACE(CONSTRAINT_NAME,'`','``'),'`') FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='session' AND COLUMN_NAME='archive_seq' AND REFERENCED_TABLE_NAME='core_command')");
        try Native.exec(storage, "PREPARE rui_archive FROM @rui_archive_ddl");
        try Native.exec(storage, "EXECUTE rui_archive");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_archive");
        try Native.exec(storage, "SET @rui_archive_ddl=(SELECT CONCAT('ALTER TABLE session DROP CHECK `',REPLACE(tc.CONSTRAINT_NAME,'`','``'),'`') FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.TABLE_NAME='session' AND tc.CONSTRAINT_TYPE='CHECK' AND LOCATE('archive_seq',cc.CHECK_CLAUSE)>0)");
        try Native.exec(storage, "PREPARE rui_archive FROM @rui_archive_ddl");
        try Native.exec(storage, "EXECUTE rui_archive");
        try Native.exec(storage, "DEALLOCATE PREPARE rui_archive");
        try Native.exec(storage, mysql_create);
        try Native.exec(storage, copy);
        try Native.exec(storage, "ALTER TABLE session DROP INDEX session_tab, DROP COLUMN archive_seq");
    } else {
        try Native.exec(storage, sqlite_create);
        try Native.exec(storage, copy);
        try Native.exec(storage, "DROP INDEX session_tab");
        try Native.exec(storage, "ALTER TABLE session DROP COLUMN archive_seq");
    }
}

fn dropObligationFrontier(storage: *Store) !void {
    const Native = struct {
        fn exec(store: *Store, sql: [:0]const u8) !void {
            if (store.engine == .mysql) return mysql_testing.rawExec(store, sql);
            return sqlite.exec(store.sqliteDatabase(), sql);
        }
    };
    if (storage.engine == .mysql) {
        try Native.exec(storage, "ALTER TABLE session DROP INDEX session_obligation_parent, DROP COLUMN session_obligation_parent_lead, DROP COLUMN obligation_since");
        try Native.exec(storage, "DROP INDEX session_forward_owed_message ON session_forward");
    } else {
        try Native.exec(storage, "DROP INDEX session_obligation_parent");
        try Native.exec(storage, "ALTER TABLE session DROP COLUMN obligation_since");
        try Native.exec(storage, "DROP INDEX session_forward_owed_message");
    }
}

pub fn stageObligationUpgrade(storage: *Store) !void {
    const schema = @import("schema.zig");
    try dropPinOrganization(storage);
    try dropObligationFrontier(storage);
    if (storage.engine == .mysql) {
        try mysql_testing.rawExec(storage, "UPDATE store_meta SET meta_value='72' WHERE meta_key='format'");
        try mysql_testing.rawExec(storage, schema.mysqlMigrationFrom(72).?);
    } else {
        try sqlite.exec(storage.sqliteDatabase(), "UPDATE store_meta SET meta_value='72' WHERE meta_key='format'");
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA user_version=72");
    }
}

pub const baseline_sqlite_ddl: [:0]const u8 = @embedFile("migration_baseline.sqlite.sql");
pub const baseline_mysql_ddl: [:0]const u8 = @embedFile("migration_baseline.mysql.sql");
pub const baseline_rows: [:0]const u8 = @embedFile("migration_baseline_rows.sql");
pub const expected_rows: [:0]const u8 = @embedFile("migration_expected_rows.sql");
pub const expected_mysql_rows: [:0]const u8 = blk: {
    @setEvalBranchQuota(4 * expected_rows.len);
    const first = std.mem.indexOf(u8, expected_rows, ";\n").? + 2;
    if (!std.mem.startsWith(u8, expected_rows, "INSERT INTO content(")) @compileError("migration_expected_rows.sql starts with the content rows");
    break :blk @embedFile("migration_expected_content.mysql.sql") ++ expected_rows[first..];
};
comptime {
    if (rsql.fixtureTextError(baseline_rows)) |message| @compileError("migration_baseline_rows.sql: " ++ message);
    if (rsql.fixtureTextError(expected_rows)) |message| @compileError("migration_expected_rows.sql: " ++ message);
    if (rsql.fixtureTextError(expected_mysql_rows)) |message| @compileError("migration_expected_content.mysql.sql: " ++ message);
}

pub const fixture_text_cases = [_]struct { text: []const u8, refused: bool }{
    .{ .text = "SELECT count(*) FROM turn", .refused = false },
    .{ .text = "PRAGMA foreign_keys=OFF", .refused = true },
    .{ .text = "UPDATE turn SET note='PRAGMA temp VIEW sqlite_x AS TEXT'", .refused = false },
    .{ .text = "UPDATE turn SET note='it''s' WHERE pragma_count=1", .refused = true },
    .{ .text = "SELECT name FROM pragma_table_info('turn')", .refused = true },
    .{ .text = "SELECT count(*) FROM sqlite_schema", .refused = true },
    .{ .text = "DROP TABLE turn", .refused = true },
    .{ .text = "SELECT count(*) FROM content WHERE CAST(payload AS TEXT)='x'", .refused = true },
    .{ .text = "SELECT count(*) FROM content WHERE CAST(payload as text)='x'", .refused = true },
    .{ .text = "SELECT text AS label FROM turn", .refused = false },
    .{ .text = "SELECT temperature FROM turn", .refused = false },
    .{ .text = "SELECT a||b FROM turn", .refused = true },
    .{ .text = "SELECT a FROM turn -- note", .refused = true },
    .{ .text = "INSERT OR IGNORE INTO turn VALUES (1)", .refused = true },
    .{ .text = "SELECT unixepoch() FROM turn", .refused = true },
};

fn fixtureText(comptime text: [:0]const u8) [:0]const u8 {
    mysql_dialect_check.shadowPrepareFixture(comptime rsql.fixtureTemplate(text));
    return text;
}

pub fn exec(storage: *Store, comptime sql: [:0]const u8, args: anytype) !void {
    _ = fixtureText(sql);
    if (storage.engine == .mysql) return mysql_testing.exec(storage, sql, args);
    return sqliteExec(storage.sqliteDatabase(), sql, args);
}

pub fn setLoadedToolsForTesting(storage: *Store, session: []const u8, source: []const u8) !void {
    const set = try queryU64(storage, "SELECT tool_set_id FROM session WHERE session_ref=?1", .{source});
    try exec(storage, "UPDATE session SET loaded_tool_set_id=?1 WHERE session_ref=?2", .{ set, session });
    try exec(storage, "UPDATE session_revision SET loaded_tool_set_id=(SELECT loaded_tool_set_id FROM session WHERE session_ref=?1) WHERE session_ref=?1", .{session});
}

pub fn setLegacyNullEffortForTesting(storage: *Store, session: []const u8) !void {
    try exec(storage, "UPDATE session SET reasoning_effort=NULL WHERE session_ref=?1", .{session});
    try exec(storage, "UPDATE session_revision SET reasoning_effort=NULL WHERE session_ref=?1", .{session});
    try exec(storage, "UPDATE model_operation SET previous_effort_override=NULL WHERE session_ref=?1", .{session});
}

pub fn queryU64(storage: *Store, comptime sql: [:0]const u8, args: anytype) !u64 {
    _ = fixtureText(sql);
    if (storage.engine == .mysql) return mysql_testing.queryU64(storage, sql, args);
    return sqliteQueryU64(storage.sqliteDatabase(), sql, args);
}

pub fn expectSqliteObligationProjection(comptime sql: [:0]const u8, comptime ddl_text: [:0]const u8, comptime cases: anytype) !void {
    var raw: ?*sqlite.c.sqlite3 = null;
    if (sqlite.c.sqlite3_open(":memory:", &raw) != sqlite.c.SQLITE_OK) {
        if (raw) |opened| _ = sqlite.c.sqlite3_close(opened);
        return error.StoreOpenFailed;
    }
    const local = raw.?;
    defer {
        const closed = sqlite.c.sqlite3_close(local);
        if (closed != sqlite.c.SQLITE_OK) std.log.err("obligation parity SQLite close failed: {d}", .{closed});
    }
    try sqlite.exec(local, ddl_text);
    try sqlite.exec(local, "INSERT INTO session(session_ref,obligation_since) VALUES('aaaaaa',NULL),('bbbbbb',80)");
    const statement = try sqlite.prepare(local, sql);
    defer _ = sqlite.c.sqlite3_finalize(statement);
    inline for (cases) |case| {
        const saved = if (case.saved) |n| std.fmt.comptimePrint("{d}", .{n}) else "NULL";
        const key = if (case.missing) "zzzzzz" else "aaaaaa";
        try sqlite.exec(local, "UPDATE session SET obligation_since=" ++ saved ++ " WHERE session_ref='aaaaaa'");
        try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_reset(statement));
        try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_clear_bindings(statement));
        try std.testing.expectEqual(sqlite.c.SQLITE_OK, sqlite.c.sqlite3_bind_text(statement, 1, key.ptr, @intCast(key.len), null));
        const bound = if (case.owed) |n| sqlite.c.sqlite3_bind_int64(statement, 2, @intCast(n)) else sqlite.c.sqlite3_bind_null(statement, 2);
        try std.testing.expectEqual(sqlite.c.SQLITE_OK, bound);
        const other_bound = if (case.other) |n| sqlite.c.sqlite3_bind_int64(statement, 3, @intCast(n)) else sqlite.c.sqlite3_bind_null(statement, 3);
        try std.testing.expectEqual(sqlite.c.SQLITE_OK, other_bound);
        const local_result = sqlite.c.sqlite3_step(statement);
        if (case.refused) {
            try std.testing.expectEqual(sqlite.c.SQLITE_CONSTRAINT, local_result & 0xff);
        } else {
            try std.testing.expectEqual(sqlite.c.SQLITE_DONE, local_result);
            try std.testing.expectEqual(case.rows, @as(u64, @intCast(sqlite.c.sqlite3_changes64(local))));
        }
        const check = try sqlite.prepare(local, "SELECT obligation_since FROM session ORDER BY session_ref");
        defer _ = sqlite.c.sqlite3_finalize(check);
        try std.testing.expectEqual(sqlite.c.SQLITE_ROW, sqlite.c.sqlite3_step(check));
        if (case.expected) |n| {
            try std.testing.expectEqual(n, @as(u64, @intCast(sqlite.c.sqlite3_column_int64(check, 0))));
        } else try std.testing.expectEqual(sqlite.c.SQLITE_NULL, sqlite.c.sqlite3_column_type(check, 0));
        try std.testing.expectEqual(sqlite.c.SQLITE_ROW, sqlite.c.sqlite3_step(check));
        try std.testing.expectEqual(@as(i64, 80), sqlite.c.sqlite3_column_int64(check, 0));
        try std.testing.expectEqual(sqlite.c.SQLITE_DONE, sqlite.c.sqlite3_step(check));
    }
}

pub fn sqliteExec(database: *sqlite.c.sqlite3, sql: [:0]const u8, args: anytype) !void {
    if (args.len == 0) return sqlite.exec(database, sql);
    const statement = try sqlite.prepare(database, sql);
    defer _ = sqlite.c.sqlite3_finalize(statement);
    try bindFixtureArgs(statement, args);
    try sqlite.expectDone(statement);
}

pub fn sqliteQueryU64(database: *sqlite.c.sqlite3, sql: [:0]const u8, args: anytype) !u64 {
    const statement = try sqlite.prepare(database, sql);
    defer _ = sqlite.c.sqlite3_finalize(statement);
    try bindFixtureArgs(statement, args);
    if (sqlite.c.sqlite3_step(statement) != sqlite.c.SQLITE_ROW) return error.QueryFailed;
    const value = sqlite.c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
}

pub fn zeroContent(storage: *Store, comptime ids: [:0]const u8) !void {
    _ = fixtureText("UPDATE content_chunk SET bytes=zeroblob(length(bytes)) WHERE content_id IN (" ++ ids ++ ")");
    const sql = "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id IN (" ++ ids ++ ")";
    if (comptime rsql.fixtureTextError(sql)) |message| @compileError(message ++ ": " ++ sql);
    if (storage.engine == .mysql) return mysql_testing.exec(storage, "UPDATE content_chunk SET bytes=zeroblob(length(bytes)) WHERE content_id IN (" ++ ids ++ ")", .{});
    return sqliteExec(storage.sqliteDatabase(), sql, .{});
}

pub fn withoutForeignKeys(storage: *Store, comptime sql: [:0]const u8, args: anytype) !void {
    if (storage.engine == .mysql) {
        try mysql_testing.rawExec(storage, "SET foreign_key_checks=0");
        defer mysql_testing.rawExec(storage, "SET foreign_key_checks=1") catch @panic("foreign keys stayed off");
        return exec(storage, sql, args);
    }
    try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
    defer sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON") catch @panic("foreign keys stayed off");
    try exec(storage, sql, args);
}

pub const sqlite_only = struct {
    pub fn exec(storage: *Store, sql: [:0]const u8, args: anytype) !void {
        return sqliteExec(storage.sqliteDatabase(), sql, args);
    }

    pub fn queryU64(storage: *Store, sql: [:0]const u8, args: anytype) !u64 {
        return sqliteQueryU64(storage.sqliteDatabase(), sql, args);
    }

    pub fn withoutForeignKeys(storage: *Store, sql: [:0]const u8, args: anytype) !void {
        try sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=OFF");
        defer sqlite.exec(storage.sqliteDatabase(), "PRAGMA foreign_keys=ON") catch @panic("foreign keys stayed off");
        try sqliteExec(storage.sqliteDatabase(), sql, args);
    }
};

pub const TestingStatementFault = struct {
    const c = sqlite.c;

    sql: [:0]const u8,
    running: bool = false,
    failed: u64 = 0,

    pub fn arm(self: *TestingStatementFault, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, c.SQLITE_TRACE_STMT, traced, self);
        c.sqlite3_progress_handler(database, 1, progress, self);
    }

    pub fn disarm(_: *const TestingStatementFault, database: *c.sqlite3) void {
        _ = c.sqlite3_trace_v2(database, 0, null, null);
        c.sqlite3_progress_handler(database, 0, null, null);
    }

    pub fn traced(_: c_uint, context: ?*anyopaque, statement: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatementFault = @ptrCast(@alignCast(context.?));
        self.running = std.mem.eql(u8, std.mem.span(c.sqlite3_sql(@ptrCast(statement))), self.sql);
        return 0;
    }

    pub fn progress(context: ?*anyopaque) callconv(.c) c_int {
        const self: *TestingStatementFault = @ptrCast(@alignCast(context.?));
        if (!self.running) return 0;
        self.failed += 1;
        return 1;
    }
};

pub fn failReadsOf(storage: *Store, comptime table: []const u8) !void {
    if (storage.engine == .mysql) return mysql_testing.rawExec(storage, "RENAME TABLE " ++ table ++ " TO " ++ table ++ "_unreadable;CREATE VIEW " ++ table ++ " AS SELECT * FROM " ++ table ++ "_unreadable WHERE abs(-9223372036854775808) IS NOT NULL");
    try sqlite.exec(storage.sqliteDatabase(), "ALTER TABLE " ++ table ++ " RENAME TO " ++ table ++ "_unreadable");
    try sqlite.exec(storage.sqliteDatabase(), "CREATE VIEW " ++ table ++ " AS SELECT * FROM " ++ table ++ "_unreadable " ++
        "WHERE abs(-9223372036854775808) IS NOT NULL");
}

/// Test-only: while armed, a COMMIT on a SQLite Store fails (the commit hook refuses it), so an injected commit
/// failure leaves the transaction rolled back.
pub fn failCommits(storage: *Store, armed: bool) void {
    const hook: ?*const fn (?*anyopaque) callconv(.c) c_int = if (armed) refuseCommit else null;
    _ = sqlite.c.sqlite3_commit_hook(storage.sqliteDatabase(), hook, null);
}

fn refuseCommit(_: ?*anyopaque) callconv(.c) c_int {
    return 1;
}

/// Test-only: one table as `SELECT *` returns it on either engine. Each field is its bytes, null for SQL NULL.
pub const TableRows = struct { names: []const []const u8, rows: []const []const ?[]const u8 };

pub fn tableRows(storage: *Store, arena: std.mem.Allocator, table: []const u8) !TableRows {
    if (storage.engine == .mysql) return mysql_testing.tableRows(storage, arena, table);
    return sqliteTableRows(storage.sqliteDatabase(), arena, table);
}

fn sqliteTableRows(database: *sqlite.c.sqlite3, arena: std.mem.Allocator, table: []const u8) !TableRows {
    const text = try std.fmt.allocPrintSentinel(arena, "SELECT * FROM \"{s}\"", .{table}, 0);
    const statement = try sqlite.prepare(database, text);
    defer _ = sqlite.c.sqlite3_finalize(statement);
    const count: usize = @intCast(sqlite.c.sqlite3_column_count(statement));
    const names = try arena.alloc([]const u8, count);
    for (names, 0..) |*name, i| name.* = try arena.dupe(u8, std.mem.span(sqlite.c.sqlite3_column_name(statement, @intCast(i))));
    var rows: std.ArrayList([]const ?[]const u8) = .empty;
    while (true) switch (sqlite.c.sqlite3_step(statement)) {
        sqlite.c.SQLITE_ROW => {
            const fields = try arena.alloc(?[]const u8, count);
            for (fields, 0..) |*field, i| field.* = try sqliteField(statement, @intCast(i), arena);
            try rows.append(arena, fields);
        },
        sqlite.c.SQLITE_DONE => break,
        else => return error.SqliteExecFailed,
    };
    return .{ .names = names, .rows = try rows.toOwnedSlice(arena) };
}

/// Integers are their decimal text, which is what MySQL's text protocol sends for them; text and blobs are their bytes.
fn sqliteField(statement: *sqlite.c.sqlite3_stmt, column: c_int, arena: std.mem.Allocator) !?[]const u8 {
    return switch (sqlite.c.sqlite3_column_type(statement, column)) {
        sqlite.c.SQLITE_NULL => null,
        sqlite.c.SQLITE_INTEGER => try std.fmt.allocPrint(arena, "{d}", .{sqlite.c.sqlite3_column_int64(statement, column)}),
        sqlite.c.SQLITE_FLOAT => try std.fmt.allocPrint(arena, "{x}", .{@as(u64, @bitCast(sqlite.c.sqlite3_column_double(statement, column)))}),
        sqlite.c.SQLITE_TEXT, sqlite.c.SQLITE_BLOB => blk: {
            const len: usize = @intCast(sqlite.c.sqlite3_column_bytes(statement, column));
            if (len == 0) break :blk "";
            const bytes: [*]const u8 = if (sqlite.c.sqlite3_column_type(statement, column) == sqlite.c.SQLITE_BLOB)
                @ptrCast(sqlite.c.sqlite3_column_blob(statement, column))
            else
                @ptrCast(sqlite.c.sqlite3_column_text(statement, column));
            break :blk try arena.dupe(u8, bytes[0..len]);
        },
        else => error.CorruptStore,
    };
}

/// Test-only logical-row digest (design C10): every table of the SQLite schema, row by row, as one hash that does not
/// depend on how a run numbered, timed or keyed its rows. What is normalised, and why:
/// - session references become their creation order (`created_seq`) wherever they appear, and content is hashed as
///   its stored bytes with those references replaced (`content.digest` becomes that hash);
/// - the clock readings (`clock_columns`), `store_meta` selector and id, `model_catalog_source.fetched_at`, the
///   random `action_value.handle` and the command input's digest (`core_command.input_digest`, which hashes text
///   carrying the run's references) are masked, keeping only whether each is NULL;
/// - `session_forward.forward_id` is masked only when `mask_forward_id` says so (the rerun leg, against a SQLite digest
///   masked the same way): the identity a forward takes is burned when its insert writes no row, and a recovery reloads
///   the counter from the table, so the run that reconnected numbers its surviving row differently (see `masked`);
/// - MySQL's generated `*_lead` helper columns are dropped, and tables only MySQL has (`store_owner`,
///   `content_chunk`) are outside the digest. A MySQL content's bytes come from its chunks, a SQLite content's from
///   its payload, since ContentReader would refuse a parts-form content (its digest is not a hash of its bytes).
pub fn logicalDigest(storage: *Store, mask_forward_id: bool) ![32]u8 {
    const schema = @import("schema.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ordinals = try sessionOrdinals(storage, arena);
    var payloads = try contentPayloads(storage, arena);
    var content_digests = try contentDigests(storage, arena, &ordinals, &payloads);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (comptime schema.objects(.sqlite)) |object| {
        if (object.kind != .table) continue;
        const table = try tableRows(storage, arena, object.name);
        const kept = comptime sqliteColumns(object.sql);
        var encoded: std.ArrayList([]const u8) = .empty;
        for (table.rows) |row| try encoded.append(arena, try logicalRow(arena, &ordinals, &content_digests, object.name, table.names, row, kept, mask_forward_id));
        std.mem.sort([]const u8, encoded.items, {}, lessBytes);
        hasher.update(object.name);
        hashLength(&hasher, encoded.items.len);
        for (encoded.items) |row| {
            hashLength(&hasher, row.len);
            hasher.update(row);
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn lessBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn hashLength(hasher: *std.crypto.hash.sha2.Sha256, length: usize) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, length, .little);
    hasher.update(&bytes);
}

/// Test-only reply digest (design C10): every reply a journey reads, in the order it reads them, as one hash that does
/// not depend on how a run numbered, timed or keyed its rows, or on the random identity of the Store instance. `keep`
/// records a reply where the journey receives it and returns it unchanged; a reply a call fills through an out-parameter
/// is kept after that call. Its bytes are kept until `finish`, which canonicalises them as `logicalDigest` does, and
/// masks what legitimately differs per run or per engine:
/// - a session reference (a value of a session-id type: `Bounded(session_id.bytes)`, `Bounded(session_id.max_reference_bytes)`,
///   or a `change_ring.Id`) is numbered by the order its value first appears (an entry point's own Store holds its
///   Sessions, so this Store's rows cannot number them); a session reference inside text is its creation order;
/// - a content's digest is the digest of its stored bytes with references replaced;
/// - a commit counter (`generation` of `change_ring.Token`, `change_ring.SessionToken` and `Store.RetryDeadlineRead`) is
///   not kept, on any leg: MySQL's count moves on entry points that save nothing (#1940), so it is not compared until
///   #1940 is fixed. A catalog generation (`model_facts` Source and Fact) is data and is kept;
/// - a clock reading is kept as whether it is set, as `clock_columns` masks it in the rows, and a Unix second in text is
///   masked the same way;
/// - a Store's selector (`HistoricalSettings.store`, its location), a session affinity (a hash over that selector) and an
///   action's `sender_handle` (random per run) are kept as whether they are set, as logicalDigest masks their rows;
/// - a forward's identity (`forward_id`, and the integer of a `forward` union) is kept on the plain legs and left out by
///   `finish(storage, true)`, the rerun leg's comparison: that leg numbers it differently (see `masked`).
/// A tag or error name is kept as written. Replies a shared helper consumes (for example `submitTestMessage`) are not kept.
pub const ReplyDigest = struct {
    gpa: std.mem.Allocator,
    /// Every byte kept, a forward's identity included.
    stream: std.ArrayList(u8) = .empty,
    /// The same bytes with no forward identity: what `finish(storage, true)` digests.
    unforwarded: std.ArrayList(u8) = .empty,
    six: std.AutoHashMapUnmanaged([6]u8, u64) = .empty,

    pub fn init(gpa: std.mem.Allocator) ReplyDigest {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ReplyDigest) void {
        self.stream.deinit(self.gpa);
        self.unforwarded.deinit(self.gpa);
        self.six.deinit(self.gpa);
    }

    pub fn keep(self: *ReplyDigest, value: anytype) @TypeOf(value) {
        self.write(value);
        return value;
    }

    fn write(self: *ReplyDigest, value: anytype) void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .void => {},
            .bool => self.put(&.{@intFromBool(value)}),
            .int => {
                var bytes: [16]u8 = undefined;
                std.mem.writeInt(u128, &bytes, @bitCast(@as(i128, value)), .little);
                self.put(&bytes);
            },
            // The integer, not the name: a non-exhaustive enum (rsql.Positive) has values without a name.
            .@"enum" => self.write(@as(@typeInfo(T).@"enum".tag_type, @backingInt(value))),
            .optional => if (value) |inner| {
                self.put(&.{1});
                self.write(inner);
            } else self.put(&.{0}),
            .error_union => if (value) |ok| {
                self.put(&.{1});
                self.write(ok);
            } else |err| {
                self.put(&.{0});
                self.name(@errorName(err));
            },
            .error_set => self.name(@errorName(value)),
            .@"union" => {
                const tag_name = @tagName(std.meta.activeTag(value));
                self.name(tag_name);
                switch (value) {
                    inline else => |payload| {
                        if (@typeInfo(@TypeOf(payload)) == .int and std.mem.eql(u8, tag_name, "forward")) return self.writeForward(payload);
                        self.write(payload);
                    },
                }
            },
            .@"struct" => {
                if (comptime isBounded(T)) {
                    if (comptime isSessionText(T)) self.sessionText(value.slice()) else self.text(value.slice());
                    return;
                }
                // A struct's `count` names how many entries of its array are set; the rest is unset memory (Recovery.calls).
                const counted = comptime countedArray(T);
                const commit_counter = comptime isCommitCounter(T);
                inline for (@typeInfo(T).@"struct".field_names) |field_name| {
                    const field_value = @field(value, field_name);
                    if (comptime commit_counter and std.mem.eql(u8, field_name, "generation")) continue;
                    // A per-run or per-engine value, kept as whether it is set: a Store's selector (its location, masked as
                    // logicalDigest masks the store_selector row), a session affinity (a hash of that selector and the
                    // session reference), and an action's sender handle (random, as logicalDigest masks action_value.handle).
                    if (comptime maskedField(T, field_name)) {
                        self.put(&.{@intFromBool(field_value.len != 0)});
                        continue;
                    }
                    if (comptime std.mem.eql(u8, field_name, "forward_id")) {
                        self.writeForward(field_value);
                    } else if (comptime isClockField(field_name)) {
                        self.put(&.{@intFromBool(clockSet(field_value))});
                    } else if (comptime counted != null and std.mem.eql(u8, field_name, counted.?)) {
                        self.write(field_value[0..@as(usize, @intCast(value.count))]);
                    } else {
                        self.write(field_value);
                    }
                }
            },
            .array => |info| {
                if (info.child != u8) {
                    for (value) |item| self.write(item);
                } else if (T == change_ring.Id) self.sessionText(&value) else self.text(&value);
            },
            .pointer => |info| switch (info.size) {
                // A pointer to the Store or to a request view is the run's handle, not a reply's content (a view holds allocators).
                .one => if (info.child == store_core.Store) self.name("store") else if (info.child == historical_domain.RequestPage) self.name("view") else self.write(value.*),
                .slice => if (info.child == u8) self.text(value) else {
                    self.length(value.len);
                    for (value) |item| self.write(item);
                },
                else => @compileError("reply digest cannot keep " ++ @typeName(T)),
            },
            else => @compileError("reply digest cannot keep " ++ @typeName(T)),
        }
    }

    fn maskedField(comptime T: type, comptime field_name: []const u8) bool {
        if (T == historical_domain.HistoricalSettings) return std.mem.eql(u8, field_name, "store") or std.mem.eql(u8, field_name, "session_affinity");
        if (T == action_domain.ActionExecutionInput) return std.mem.eql(u8, field_name, "sender_handle");
        return false;
    }

    /// The commit counter a token or a retry read carries: each engine's count of changed rows differs (#1940).
    fn isCommitCounter(comptime T: type) bool {
        return T == change_ring.Token or T == change_ring.SessionToken or T == store_core.Store.RetryDeadlineRead;
    }

    /// The types a session reference is held in: numbered by first appearance, not by its length.
    fn isSessionText(comptime T: type) bool {
        return T == Bounded(session_id.bytes) or T == Bounded(session_id.max_reference_bytes);
    }

    /// The array a struct's `count` sizes, when it has one: the first array field besides `count`.
    fn countedArray(comptime T: type) ?[]const u8 {
        if (!@hasField(T, "count")) return null;
        for (@typeInfo(T).@"struct".field_names) |field_name| {
            if (std.mem.eql(u8, field_name, "count")) continue;
            if (@typeInfo(@FieldType(T, field_name)) == .array) return field_name;
        }
        return null;
    }

    fn isClockField(comptime field_name: []const u8) bool {
        @setEvalBranchQuota(10_000);
        for (clock_columns) |clock| if (std.mem.eql(u8, field_name, clock)) return true;
        return std.mem.endsWith(u8, field_name, "_at") or std.mem.endsWith(u8, field_name, "_at_ms") or
            std.mem.eql(u8, field_name, "since") or std.mem.eql(u8, field_name, "now_ms") or std.mem.eql(u8, field_name, "at");
    }

    fn clockSet(value: anytype) bool {
        return switch (@typeInfo(@TypeOf(value))) {
            .optional => value != null,
            .int => value != 0,
            else => @compileError("reply digest cannot mask a clock " ++ @typeName(@TypeOf(value))),
        };
    }

    /// A session reference's text: a six-byte value is numbered by the order it first appears; any other length is kept.
    fn sessionText(self: *ReplyDigest, bytes: []const u8) void {
        self.length(bytes.len);
        if (bytes.len != session_id.bytes) return self.put(bytes);
        const gop = self.six.getOrPut(self.gpa, bytes[0..session_id.bytes].*) catch |err| @panic(@errorName(err));
        if (!gop.found_existing) gop.value_ptr.* = self.six.count() - 1;
        var number: [8]u8 = undefined;
        std.mem.writeInt(u64, &number, gop.value_ptr.*, .little);
        self.put(&number);
    }

    fn text(self: *ReplyDigest, bytes: []const u8) void {
        self.length(bytes.len);
        self.put(bytes);
    }

    /// A tag or an error name, kept as written (it is not a session reference, whatever its length).
    fn name(self: *ReplyDigest, bytes: []const u8) void {
        self.text(bytes);
    }

    fn length(self: *ReplyDigest, count: usize) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, count, .little);
        self.put(&bytes);
    }

    fn put(self: *ReplyDigest, bytes: []const u8) void {
        self.stream.appendSlice(self.gpa, bytes) catch |err| @panic(@errorName(err));
        self.unforwarded.appendSlice(self.gpa, bytes) catch |err| @panic(@errorName(err));
    }

    /// A forward's identity: kept in `stream` only, so `finish(storage, true)` leaves it out.
    fn writeForward(self: *ReplyDigest, value: anytype) void {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &bytes, @bitCast(@as(i128, value)), .little);
        self.stream.appendSlice(self.gpa, &bytes) catch |err| @panic(@errorName(err));
    }

    /// The digest of every reply kept, canonicalised against the run's rows and its Store instance. `mask_forward` leaves
    /// out each forward's identity: the rerun leg's comparison.
    pub fn finish(self: *const ReplyDigest, storage: *Store, mask_forward: bool) ![32]u8 {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var ordinals = try sessionOrdinals(storage, arena);
        var payloads = try contentPayloads(storage, arena);
        var content_digests = try contentDigests(storage, arena, &ordinals, &payloads);
        const canon: Canon = .{ .gpa = self.gpa, .sessions = &ordinals, .digests = &content_digests, .instance = &storage.instance };
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        try canon.apply(if (mask_forward) self.unforwarded.items else self.stream.items, &out);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out.items, &digest, .{});
        return digest;
    }

    const Canon = struct {
        gpa: std.mem.Allocator,
        sessions: *const Ordinals,
        digests: *const Digests,
        instance: *const [16]u8,

        fn apply(self: Canon, bytes: []const u8, out: *std.ArrayList(u8)) !void {
            const instance_hex = std.fmt.bytesToHex(self.instance.*, .lower);
            var i: usize = 0;
            while (i < bytes.len) {
                if (i + 16 <= bytes.len and std.mem.eql(u8, bytes[i..][0..16], self.instance)) {
                    try out.appendSlice(self.gpa, "instance");
                    i += 16;
                    continue;
                }
                if (i + 32 <= bytes.len and std.mem.eql(u8, bytes[i..][0..32], &instance_hex)) {
                    try out.appendSlice(self.gpa, "instance");
                    i += 32;
                    // A text token's commit counter follows the instance as ".N" (the read version).
                    if (i < bytes.len and bytes[i] == '.') {
                        i += 1;
                        while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
                    }
                    continue;
                }
                if (i + 32 <= bytes.len) if (self.digests.get(bytes[i..][0..32].*)) |canonical| {
                    try out.appendSlice(self.gpa, "content");
                    try out.appendSlice(self.gpa, &canonical);
                    i += 32;
                    continue;
                };
                // A reading of the clock in a text reply: a Unix second (ten digits from 1), as the rows mask a time.
                if (std.ascii.isDigit(bytes[i]) and (i == 0 or !std.ascii.isDigit(bytes[i - 1]))) {
                    var end = i;
                    while (end < bytes.len and std.ascii.isDigit(bytes[end])) end += 1;
                    if (end - i == 10 and bytes[i] == '1') {
                        try out.appendSlice(self.gpa, "clock");
                        i = end;
                        continue;
                    }
                }
                if (i + 6 <= bytes.len) if (self.sessions.get(bytes[i..][0..6].*)) |ordinal| {
                    var number: [8]u8 = undefined;
                    std.mem.writeInt(u64, &number, ordinal, .little);
                    try out.appendSlice(self.gpa, "session");
                    try out.appendSlice(self.gpa, &number);
                    i += 6;
                    continue;
                };
                try out.append(self.gpa, bytes[i]);
                i += 1;
            }
        }
    };
};

const Ordinals = std.AutoHashMap([6]u8, u64);

fn sessionOrdinals(storage: *Store, arena: std.mem.Allocator) !Ordinals {
    const sessions = try tableRows(storage, arena, "session");
    const ref_at = columnIndex(sessions.names, "session_ref");
    const seq_at = columnIndex(sessions.names, "created_seq");
    const Pair = struct { ref: []const u8, seq: u64 };
    const pairs = try arena.alloc(Pair, sessions.rows.len);
    for (sessions.rows, pairs) |row, *pair| {
        const ref = row[ref_at] orelse return error.CorruptStore;
        if (ref.len != 6) return error.CorruptStore;
        pair.* = .{ .ref = ref, .seq = try std.fmt.parseInt(u64, row[seq_at] orelse return error.CorruptStore, 10) };
    }
    std.mem.sort(Pair, pairs, {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return a.seq < b.seq;
        }
    }.lessThan);
    var ordinals: Ordinals = .init(arena);
    for (pairs, 1..) |pair, ordinal| try ordinals.put(pair.ref[0..6].*, ordinal);
    return ordinals;
}

/// Each content's stored bytes by content id. Read from the engine's own storage, not ContentReader: a parts-form
/// content's digest is not a hash of its bytes, so ContentReader would refuse it and fence the Store.
fn contentPayloads(storage: *Store, arena: std.mem.Allocator) !std.AutoHashMap(i64, []const u8) {
    var payloads: std.AutoHashMap(i64, []const u8) = .init(arena);
    if (storage.engine != .mysql) {
        const content = try tableRows(storage, arena, "content");
        const id_at = columnIndex(content.names, "content_id");
        const payload_at = columnIndex(content.names, "payload");
        for (content.rows) |row| try payloads.put(try std.fmt.parseInt(i64, row[id_at] orelse return error.CorruptStore, 10), row[payload_at] orelse return error.CorruptStore);
        return payloads;
    }
    const chunks = try tableRows(storage, arena, "content_chunk");
    const id_at = columnIndex(chunks.names, "content_id");
    const index_at = columnIndex(chunks.names, "chunk_index");
    const bytes_at = columnIndex(chunks.names, "bytes");
    const Chunk = struct { id: i64, index: u64, bytes: []const u8 };
    const ordered = try arena.alloc(Chunk, chunks.rows.len);
    for (chunks.rows, ordered) |row, *chunk| chunk.* = .{
        .id = try std.fmt.parseInt(i64, row[id_at] orelse return error.CorruptStore, 10),
        .index = try std.fmt.parseInt(u64, row[index_at] orelse return error.CorruptStore, 10),
        .bytes = row[bytes_at] orelse return error.CorruptStore,
    };
    std.mem.sort(Chunk, ordered, {}, struct {
        fn lessThan(_: void, a: Chunk, b: Chunk) bool {
            return a.id < b.id or (a.id == b.id and a.index < b.index);
        }
    }.lessThan);
    var index: usize = 0;
    while (index < ordered.len) {
        const id = ordered[index].id;
        var joined: std.ArrayList(u8) = .empty;
        while (index < ordered.len and ordered[index].id == id) : (index += 1) try joined.appendSlice(arena, ordered[index].bytes);
        try payloads.put(id, try joined.toOwnedSlice(arena));
    }
    return payloads;
}

fn columnIndex(names: []const []const u8, name: []const u8) usize {
    for (names, 0..) |column, i| if (std.mem.eql(u8, column, name)) return i;
    @panic("logicalDigest: a table lost a column the digest names");
}

fn canonicalText(arena: std.mem.Allocator, ordinals: *const Ordinals, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 6 <= bytes.len) if (ordinals.get(bytes[i..][0..6].*)) |ordinal| {
            try out.appendSlice(arena, try std.fmt.allocPrint(arena, "#{d}", .{ordinal}));
            i += 6;
            continue;
        };
        try out.append(arena, bytes[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

fn logicalRow(arena: std.mem.Allocator, ordinals: *const Ordinals, content_digests: *const Digests, table: []const u8, names: []const []const u8, row: []const ?[]const u8, kept: []const []const u8, mask_forward_id: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const is_content = std.mem.eql(u8, table, "content");
    for (names, row) |name, field| {
        // MySQL adds generated index helpers (`*_lead`) that SQLite does not have: not part of the logical rows.
        if (!contains(kept, name)) continue;
        if (is_content and std.mem.eql(u8, name, "payload")) continue;
        var value: ?[]const u8 = field;
        if (is_content and std.mem.eql(u8, name, "digest")) {
            value = try canonicalDigest(arena, content_digests, field);
        } else if (std.mem.eql(u8, name, "field_metadata")) {
            // Three (length, digest) entries, each digest a content's: the digest as its canonical content's.
            const copy = try arena.dupe(u8, field orelse return error.CorruptStore);
            var at: usize = 0;
            while (at + 40 <= copy.len) : (at += 40) {
                if (content_digests.get(copy[at + 8 ..][0..32].*)) |canonical| @memcpy(copy[at + 8 ..][0..32], &canonical);
            }
            value = copy;
        } else if (masked(table, name, names, row, mask_forward_id)) {
            value = if (field == null) null else "masked";
        } else if (field) |bytes| {
            value = try canonicalText(arena, ordinals, bytes);
        }
        if (value) |bytes| {
            try out.append(arena, 1);
            try appendLength(arena, &out, bytes.len);
            try out.appendSlice(arena, bytes);
        } else try out.append(arena, 0);
    }
    return out.toOwnedSlice(arena);
}

/// The column names of a rendered CREATE TABLE: the indented definitions that are not table constraints.
fn sqliteColumns(comptime sql: []const u8) []const []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var names: []const []const u8 = &.{};
        var lines = std.mem.splitScalar(u8, sql, '\n');
        _ = lines.next();
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] != ' ') continue;
            const body = std.mem.trimStart(u8, line, " ");
            const end = std.mem.indexOfAny(u8, body, " (,") orelse continue;
            const word = body[0..end];
            const constraint = for ([_][]const u8{ "PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "CONSTRAINT" }) |keyword| {
                if (std.mem.eql(u8, word, keyword)) break true;
            } else false;
            if (!constraint) names = names ++ &[_][]const u8{word};
        }
        return names;
    }
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn appendLength(arena: std.mem.Allocator, out: *std.ArrayList(u8), length: usize) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, length, .little);
    try out.appendSlice(arena, &bytes);
}

/// Clock readings: each Store's run takes its own. Kept as NULL or not, so a missing time still differs.
const clock_columns = [_][]const u8{
    "admitted_at", "attempt_at",       "background_at", "changed_at",  "created_at",  "decided_at",      "delivered_at",
    "fetched_at",  "outcome_at",       "published_at",  "recorded_at", "resolved_at", "retry_due_at_ms", "retry_scheduled_at",
    "stopped_at",  "obligation_since",
};

fn masked(table: []const u8, name: []const u8, names: []const []const u8, row: []const ?[]const u8, mask_forward_id: bool) bool {
    // A digest of the command's input, which carries the run's session references: a digest of text this digest
    // cannot rebuild from the rows.
    if (std.mem.eql(u8, table, "core_command") and std.mem.eql(u8, name, "input_digest")) return true;
    // Burned identity: `forward.queue` takes a forward_id before its INSERT ... SELECT, which writes no row when the
    // session has no parent or the same forward is already queued (the second queue of a source, in the journey). The
    // counter keeps that number, so later forwards number one higher than the rows show. A recovery reloads the counter
    // from the table maximum and drops the burned number, so the rerun leg's surviving forward takes a lower number.
    // In the journey no other identity diverges between the legs. Masked only where the caller says so (the rerun leg,
    // compared with a SQLite digest masked the same way); every other column is still compared.
    if (mask_forward_id and std.mem.eql(u8, table, "session_forward") and std.mem.eql(u8, name, "forward_id")) return true;
    // A random handle the Store draws for each published value (32 hex digits), so it differs per run by design.
    if (std.mem.eql(u8, table, "action_value") and std.mem.eql(u8, name, "handle")) return true;
    for (clock_columns) |clock| if (std.mem.eql(u8, name, clock)) return true;
    if (std.mem.eql(u8, table, "store_meta") and std.mem.eql(u8, name, "meta_value")) {
        const key = row[columnIndex(names, "meta_key")] orelse return false;
        return std.mem.eql(u8, key, "store_selector") or std.mem.eql(u8, key, "store_id");
    }
    return false;
}

/// Each content's raw digest mapped to the digest of its stored bytes with session references replaced: what a
/// content's digest means in the logical rows, whatever the run's references were.
const Digests = std.AutoHashMap([32]u8, [32]u8);

fn contentDigests(storage: *Store, arena: std.mem.Allocator, ordinals: *const Ordinals, payloads: *const std.AutoHashMap(i64, []const u8)) !Digests {
    const content = try tableRows(storage, arena, "content");
    const id_at = columnIndex(content.names, "content_id");
    const length_at = columnIndex(content.names, "byte_length");
    const digest_at = columnIndex(content.names, "digest");
    var digests: Digests = .init(arena);
    for (content.rows) |row| {
        const raw = row[digest_at] orelse return error.CorruptStore;
        if (raw.len != 32) return error.CorruptStore;
        const id = try std.fmt.parseInt(i64, row[id_at] orelse return error.CorruptStore, 10);
        const length = try std.fmt.parseInt(usize, row[length_at] orelse return error.CorruptStore, 10);
        // An empty content has no MySQL chunk; its bytes are empty all the same.
        const bytes = payloads.get(id) orelse if (length == 0) "" else return error.CorruptStore;
        if (bytes.len != length) return error.CorruptStore;
        const canonical = try canonicalText(arena, ordinals, bytes);
        var hashed: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(canonical, &hashed, .{});
        try digests.put(raw[0..32].*, hashed);
    }
    return digests;
}

fn canonicalDigest(arena: std.mem.Allocator, digests: *const Digests, field: ?[]const u8) ![]const u8 {
    const raw = field orelse return error.CorruptStore;
    if (raw.len != 32) return error.CorruptStore;
    const canonical = digests.get(raw[0..32].*) orelse return error.CorruptStore;
    return arena.dupe(u8, &canonical);
}

pub const Blob = struct { bytes: []const u8 };

fn bindFixtureArgs(statement: *sqlite.c.sqlite3_stmt, args: anytype) !void {
    inline for (args, 1..) |value, index| {
        if (@TypeOf(value) == Blob) {
            try sqlite.bindBlob(statement, index, value.bytes);
        } else switch (@typeInfo(@TypeOf(value))) {
            .int, .comptime_int => try sqlite.bindI64(statement, index, value),
            else => try sqlite.bindText(statement, index, value),
        }
    }
}

pub fn completeConfiguration(key: []const u8, session_ref: []const u8, workspace: []const u8, model: []const u8) !wire_request.ConfigureCommand {
    var command: wire_request.ConfigureCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    command.configuration.workspace.state = .value;
    try command.configuration.workspace.value.set(workspace);
    command.configuration.provider.state = .value;
    try command.configuration.provider.value.set("codex");
    command.configuration.model.state = .value;
    try command.configuration.model.value.set(model);
    if (session_ref.len == 0) {
        command.configuration.tools = try .of(&.{ "bash", "web_search" });
        command.configuration.permission_mode.state = .value;
        try command.configuration.permission_mode.value.set("bypass");
        command.configuration.compaction_trigger.state = .value;
        try command.configuration.compaction_trigger.value.set("115200");
        const low_models = [_][]const u8{ "gpt-6-luna", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5" };
        const effort: ?[]const u8 = for (low_models) |name| {
            if (std.mem.eql(u8, model, name)) break "low";
        } else null;
        if (effort) |value| {
            command.configuration.reasoning_effort.state = .value;
            try command.configuration.reasoning_effort.value.set(value);
        } else command.configuration.reasoning_effort.state = .explicit_null;
    }
    return command;
}

pub fn completeMessage(
    key: []const u8,
    session_ref: []const u8,
    file: std.Io.File,
    text: []const u8,
) !wire_request.MessageCommand {
    var command: wire_request.MessageCommand = .{};
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

pub fn canonicalCwd(io: std.Io, buffer: []u8) ![]const u8 {
    var directory = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer directory.close(io);
    const length = try directory.realPath(io, buffer);
    return buffer[0..length];
}

pub const testing_absent_model_evidence: protocol.Bounded(775) = .{
    .bytes = .{1} ++ @as([774]u8, @splat(0)),
    .len = 7,
};

pub fn configureTestSession(
    storage: *Store,
    key: []const u8,
) !protocol.Bounded(protocol.max_session_bytes) {
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try canonicalCwd(std.testing.io, &workspace_buffer);
    var command = try completeConfiguration(key, "", workspace, "model-a");
    const reply = try storage.configure(&command, .{});
    try std.testing.expect(reply == .accepted);
    return reply.accepted.session;
}

pub fn submitTestMessage(
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
    try std.testing.expect(storage.submitMessageWithModel(&command, null, .{}) == .accepted);
}

pub const TestingAnswerPart = struct { encoded: []const u8, decoded: []const u8 };

pub const MessagePart = struct {
    bytes: []const u8,
    kind: @import("../InputCapture.zig").Incoming = .text,
};

pub fn submitTestMessageParts(storage: *Store, tmp: *std.testing.TmpDir, key: []const u8, session: []const u8, parts: []const MessagePart) !void {
    return submitTestMessagePartsWithSkills(storage, tmp, key, session, parts, null);
}

pub fn submitTestMessagePartsWithSkills(storage: *Store, tmp: *std.testing.TmpDir, key: []const u8, session: []const u8, parts: []const MessagePart, captured: ?*const @import("domain/skills.zig").MessageCapture) !void {
    const Capture = @import("../InputCapture.zig");
    const custody = @import("../content_custody.zig");
    var used: std.atomic.Value(u64) = .init(0);
    var capture: Capture = undefined;
    {
        const spool = try tmp.dir.createFile(std.testing.io, "test-message-spool", .{ .read = true });
        errdefer spool.close(std.testing.io);
        const index = try tmp.dir.createFile(std.testing.io, "test-message-index", .{ .read = true });
        errdefer index.close(std.testing.io);
        try tmp.dir.deleteFile(std.testing.io, "test-message-spool");
        try tmp.dir.deleteFile(std.testing.io, "test-message-index");
        capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = 4 * 1024 * 1024 });
    }
    defer capture.close();
    for (parts) |part| {
        try capture.begin(part.kind, part.bytes.len);
        var at: usize = 0;
        while (at < part.bytes.len) {
            var allowance = part.bytes.len - at;
            at += try capture.append(part.bytes[at..], &allowance, false);
        }
        try capture.end();
    }
    var command: custody.MessageCommand = .{};
    try command.key.set(key);
    try command.session.set(session);
    const loan = try capture.seal();
    const reply = if (captured) |skills|
        try storage.submitMessagePartsCapturedSkillsForTesting(&command, loan, null, skills)
    else
        try storage.submitMessageParts(&command, loan, null, .{});
    try std.testing.expect(reply == .accepted);
}

pub fn settleTestActionParts(storage: *Store, tmp: *std.testing.TmpDir, binding: @import("domain/action.zig").ActionAttemptBinding, parts: []const MessagePart) !void {
    const Capture = @import("../InputCapture.zig");
    var used: std.atomic.Value(u64) = .init(0);
    var capture: Capture = undefined;
    {
        const spool = try tmp.dir.createFile(std.testing.io, "test-action-spool", .{ .read = true });
        errdefer spool.close(std.testing.io);
        const index = try tmp.dir.createFile(std.testing.io, "test-action-index", .{ .read = true });
        errdefer index.close(std.testing.io);
        try tmp.dir.deleteFile(std.testing.io, "test-action-spool");
        try tmp.dir.deleteFile(std.testing.io, "test-action-index");
        capture.init(std.testing.io, spool, index, .{ .used = &used, .limit = 4 * 1024 * 1024 });
    }
    defer capture.close();
    for (parts) |part| {
        try capture.begin(part.kind, part.bytes.len);
        var at: usize = 0;
        while (at < part.bytes.len) {
            var allowance = part.bytes.len - at;
            at += try capture.append(part.bytes[at..], &allowance, false);
        }
        try capture.end();
    }
    const reply = (try storage.settleActionAttemptParts(binding, .succeeded, try capture.seal(), .{})).outcome;
    try std.testing.expectEqual(@import("domain/action.zig").ActionSettlement.Outcome.effect, reply);
}

pub fn testingPublicProjection(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    parts: []const TestingAnswerPart,
) !protocol.ConversationContent {
    const session = try configureTestSession(storage, "projection-config");
    try answerTestTurn(storage, tmp, session.slice(), "projection", parts);
    const page = try store_core.publicConversationPageForTesting(storage, .{ .session = session });
    try std.testing.expect(page.items[0].kind == .assistant);
    return .{ .session = session, .position = page.items[0].position };
}

pub fn answerTestTurn(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    session: []const u8,
    comptime name: []const u8,
    parts: []const TestingAnswerPart,
) !void {
    try submitTestMessage(storage, tmp, name ++ "-input", name ++ "-key", session, "input");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try settleAnswerTestTurn(storage, tmp, binding, name, parts);
}

/// Settles a final answer for the admitted attempt `binding` without admitting a Message first. A Message a person
/// admits after an approval declines it, so a fixture that keeps the approval open settles the answer through here.
pub fn settleAnswerTestTurn(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    binding: AttemptBinding,
    comptime name: []const u8,
    parts: []const TestingAnswerPart,
) !void {
    var capacity: usize = 128;
    for (parts) |part| capacity += part.encoded.len + 32;
    const source_buffer = try std.testing.allocator.alloc(u8, capacity);
    defer std.testing.allocator.free(source_buffer);
    var writer = std.Io.Writer.fixed(source_buffer);
    var digest = protocol.contentHasher();
    var decoded_length: u64 = 0;
    try writer.writeAll("{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[");
    for (parts, 0..) |part, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{{\"type\":\"output_text\",\"text\":\"{s}\"}}", .{part.encoded});
        digest.update(part.decoded);
        decoded_length += part.decoded.len;
    }
    try writer.writeAll("]}");
    const bytes = writer.buffered();
    const source = try tmp.dir.createFile(std.testing.io, name ++ "-source", .{ .read = true });
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, bytes);
    try source.sync(std.testing.io);
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    var metadata_used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var metadata = try OutputMetadataWriter.init(std.testing.io, root_buffer[0..root_length], name ++ "-metadata", .{ .used = &metadata_used, .limit = 1 << 20 }, false, &retained);
    defer metadata.deinit();
    _ = try output_decode.recordItemForTesting(&metadata, source, 0, bytes.len, 0, .assistant_response);
    try metadata.sealForRead();
    const output = ValidatedOutput{
        .source = source,
        .source_length = bytes.len,
        .metadata = metadata.file,
        .item_count = 1,
        .call_count = 0,
        .answer_item_ordinal = 0,
        .answer_length = decoded_length,
        .answer_digest = digest.finalResult(),
        .response_id = .{},
        .model_evidence = testing_absent_model_evidence,
        .request_id = .{},
    };
    try storage.settleModelSuccess(binding, &output, .{});
}

pub fn setHistoryFloorForTesting(storage: *Store, operation: u64, text: []const u8, level: u64) !void {
    if (!@import("builtin").is_test) @compileError("test-only Store fixture");
    const digest = protocol.contentDigest(text);
    try exec(storage, "UPDATE model_operation SET history_floor=(SELECT e.session_position FROM conversation_entry e JOIN content c ON c.content_id=e.content_id " ++
        "WHERE e.session_ref=model_operation.session_ref AND c.digest=?2 AND c.private=0),history_level=?3,history_dropped=0 WHERE operation_id=?1", .{ operation, Blob{ .bytes = &digest }, level });
}

pub fn turnEndedForTesting(storage: *Store, turn: u64, outcome: []const u8) !bool {
    if (!@import("builtin").is_test) @compileError("test-only Store fixture");
    return try queryU64(storage, "SELECT count(*) FROM turn WHERE turn_id=?1 AND outcome_code=?2", .{ turn, outcome }) == 1;
}

pub fn settleCompactionForTesting(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, kinds: []const OutputItemKind) !void {
    if (!@import("builtin").is_test) @compileError("test-only Store fixture");
    const source = try tmp.dir.createFile(std.testing.io, "compaction-output", .{ .read = true });
    defer source.close(std.testing.io);
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var metadata = try OutputMetadataWriter.init(std.testing.io, root[0..root_length], "compaction-metadata", .{ .used = &used, .limit = 4096 }, false, &retained);
    defer metadata.deinit();
    var offset: u64 = 0;
    var calls: u64 = 0;
    for (kinds, 0..) |kind, ordinal| {
        var id_buffer: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buffer, "{s}-{d}", .{ @tagName(kind), ordinal });
        const fields: []const u8 = switch (kind) {
            .reasoning => ",\"summary\":[],\"encrypted_content\":\"opaque\"",
            .function_call => ",\"name\":\"bash\",\"call_id\":\"c\",\"arguments\":\"{}\"",
            .compaction => ",\"encrypted_content\":\"opaque\"",
            .web_search_call => ",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"q\"}",
            .message => ",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"\"}]",
        };
        var item_buffer: [256]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&item_buffer, "{{\"type\":\"{s}\",\"id\":\"{s}\"{s}}}", .{ @tagName(kind), id, fields });
        if (kind == .function_call) calls += 1;
        try source.writeStreamingAll(std.testing.io, bytes);
        try source.sync(std.testing.io);
        const operation: output_format.ModelOperationKind = if (kind == .compaction) .compaction else .assistant_response;
        _ = try output_decode.recordItemForTesting(&metadata, source, offset, bytes.len, ordinal, operation);
        offset += bytes.len;
    }
    try metadata.sealForRead();
    try storage.settleModelSuccess(binding, &.{
        .source = source,
        .source_length = offset,
        .metadata = metadata.file,
        .item_count = kinds.len,
        .call_count = calls,
        .answer_length = if (try storage.modelOperationKind(binding) == .compaction) 6 else 0,
        .answer_digest = protocol.contentDigest("answer"),
        .response_id = .{},
        .model_evidence = testing_absent_model_evidence,
        .request_id = .{},
    }, .{});
}

pub fn settleItemsForTesting(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, items: []const []const u8, answer: []const u8) !void {
    return settleSelectedItemsForTesting(storage, tmp, binding, items, null, answer);
}

pub fn settleItemsForTestingWithUsage(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, items: []const []const u8, answer: []const u8, usage: []const u8) !void {
    return settleSelectedItemsAndUsageForTesting(storage, tmp, binding, items, null, answer, usage);
}

pub fn settleSelectedItemsForTesting(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, items: []const []const u8, selected: ?u64, answer: []const u8) !void {
    return settleSelectedItemsAndUsageForTesting(storage, tmp, binding, items, selected, answer, null);
}

fn settleSelectedItemsAndUsageForTesting(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, items: []const []const u8, selected: ?u64, answer: []const u8, usage: ?[]const u8) !void {
    if (!@import("builtin").is_test) @compileError("test-only Store fixture");
    const source = try tmp.dir.createFile(std.testing.io, "items-output", .{ .read = true, .truncate = true });
    defer source.close(std.testing.io);
    var root: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var metadata = try OutputMetadataWriter.init(std.testing.io, root[0..root_length], "items-metadata", .{ .used = &used, .limit = 1 << 20 }, false, &retained);
    defer metadata.deinit();
    var offset: u64 = 0;
    var answer_item: ?u64 = null;
    var calls: u64 = 0;
    for (items, 0..) |bytes, ordinal| {
        try source.writeStreamingAll(std.testing.io, bytes);
        try source.sync(std.testing.io);
        const record = try output_decode.recordItemForTesting(&metadata, source, offset, bytes.len, ordinal, .assistant_response);
        if (record.kind == .message) answer_item = ordinal;
        if (record.kind == .function_call) calls += 1;
        offset += bytes.len;
    }
    if (usage) |bytes| {
        try source.writeStreamingAll(std.testing.io, bytes);
        try source.sync(std.testing.io);
        try metadata.append(&.{
            .tag = .usage,
            .start = offset,
            .length = bytes.len,
            .content_digest = protocol.contentDigest(bytes),
            .usage = try output_decode.readUsageForTesting(std.testing.io, source, offset, bytes.len),
        });
        offset += bytes.len;
    }
    try metadata.sealForRead();
    try storage.settleModelSuccess(binding, &.{
        .source = source,
        .source_length = offset,
        .metadata = metadata.file,
        .item_count = items.len,
        .call_count = calls,
        .answer_item_ordinal = selected orelse answer_item,
        .answer_length = answer.len,
        .answer_digest = protocol.contentDigest(answer),
        .response_id = .{},
        .model_evidence = testing_absent_model_evidence,
        .request_id = .{},
    }, .{});
}

pub const content_beside_tools = "SELECT count(*) FROM content WHERE (content_id NOT IN (SELECT description_content_id FROM tool_record) " ++
    "AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record)) OR content_id IN (SELECT instructions_content_id FROM session_revision) " ++
    "OR content_id IN (SELECT output_schema_content_id FROM session_revision WHERE output_schema_content_id IS NOT NULL)";

pub fn observeCommandForTesting(storage: *Store, key: []const u8) !command_domain.CommandObservation {
    var out: store_core.Observed = undefined;
    try storage.observeCommand(key, null, &out);
    return out.full.observation;
}

pub const operation_offer_migration_seed: [:0]const u8 =
    "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) " ++
    "SELECT 'offer-migration-update',1,'d8mv7p',input_digest,1,'',2,0,100 FROM core_command WHERE command_key='fixture-answer-config';" ++
    "INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,loaded_tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label) " ++
    "SELECT session_ref,2,'offer-migration-update',workspace,provider,model,instructions_content_id,0,tool_set_id,2,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label FROM session_revision WHERE session_ref='d8mv7p' AND revision=1;" ++
    "UPDATE session SET revision=2,loaded_tool_set_id=2,next_position=100 WHERE session_ref='d8mv7p';" ++
    "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,attempt_ordinal,resolution_code,resolved_at) " ++
    "VALUES(99,1,'d8mv7p',2,1,99,0,1,'failed',1)";

pub const operation_effort_migration_seed: [:0]const u8 =
    "UPDATE session SET codec='openai-responses/2',revision=3,reasoning_effort='high',next_position=16,label='unrelated' WHERE session_ref='d8mv7p';" ++
    "UPDATE model_operation SET reasoning_effort='low' WHERE operation_id=1;" ++
    "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) SELECT 'effort-migration-high',1,'d8mv7p',input_digest,1,'',2,0,100 FROM core_command WHERE command_key='fixture-answer-config';" ++
    "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) SELECT 'effort-migration-last',1,'d8mv7p',input_digest,1,'',3,0,101 FROM core_command WHERE command_key='fixture-answer-config';" ++
    "INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label) " ++
    "SELECT session_ref,2,'effort-migration-high',workspace,provider,model,instructions_content_id,0,tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,'high',label FROM session_revision WHERE session_ref='d8mv7p' AND revision=1;" ++
    "INSERT INTO session_revision(session_ref,revision,command_key,workspace,provider,model,instructions_content_id,instructions_updated,tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,reasoning_effort,label) " ++
    "SELECT session_ref,3,'effort-migration-last',workspace,provider,model,instructions_content_id,0,tool_set_id,permission_mode,output_schema_content_id,compaction_trigger,output_reservation,'high','unrelated' FROM session_revision WHERE session_ref='d8mv7p' AND revision=1;" ++
    "INSERT INTO session_change(session_ref,position,ordinal,revision,field,changed_at) VALUES('d8mv7p',6,0,2,'reasoning_effort',1793781800),('d8mv7p',14,0,3,'label',1793781801);" ++
    "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,purpose,output_reservation,reasoning_effort,output_item_count,attempt_ordinal,resolution_code,resolved_at,tool_set_id) " ++
    "VALUES(99,1,'d8mv7p',2,1,7,0,0,'high',0,1,'answer',1793781800,4),(100,1,'d8mv7p',2,1,11,1,0,'high',1,1,'compacted',1793781800,4);" ++
    "INSERT INTO model_output_item(operation_id,item_ordinal,session_ref,session_position,item_kind,attempt_ordinal,item_id_digest,replay_omits_reasoning_text,phase,extras_content_id,part_count) " ++
    "SELECT 100,0,'d8mv7p',12,4,1,item_id_digest,0,0,4,0 FROM model_output_item WHERE operation_id=1 AND item_ordinal=0;" ++
    "INSERT INTO model_operation(operation_id,turn_id,session_ref,settings_revision,input_cutoff,admission_position,output_reservation,reasoning_effort,attempt_ordinal,retry_due_at_ms,attempt_at,tool_set_id) " ++
    "VALUES(101,1,'d8mv7p',3,1,15,0,'high',1,0,1793781801,4)";

pub const EffortMigrationChoice = enum {
    retained,
    back_to_top,
    new_choice,
    legacy_new_choice,

    pub fn sql(choice: EffortMigrationChoice) [:0]const u8 {
        return switch (choice) {
            .retained => "UPDATE session SET label=label WHERE session_ref='d8mv7p'",
            .back_to_top => "UPDATE session_revision SET reasoning_effort='low' WHERE session_ref='d8mv7p' AND revision=3;UPDATE session SET reasoning_effort='low' WHERE session_ref='d8mv7p';UPDATE model_operation SET reasoning_effort='low' WHERE operation_id=101;UPDATE session_change SET field='reasoning_effort' WHERE session_ref='d8mv7p' AND revision=3",
            .new_choice => "UPDATE session_revision SET reasoning_effort='xhigh' WHERE session_ref='d8mv7p' AND revision=3;UPDATE session SET reasoning_effort='xhigh' WHERE session_ref='d8mv7p';UPDATE model_operation SET reasoning_effort='xhigh' WHERE operation_id=101;UPDATE session_change SET field='reasoning_effort' WHERE session_ref='d8mv7p' AND revision=3",
            .legacy_new_choice => "UPDATE session_revision SET reasoning_effort='xhigh' WHERE session_ref='d8mv7p' AND revision=3;UPDATE session SET reasoning_effort='xhigh' WHERE session_ref='d8mv7p';UPDATE model_operation SET reasoning_effort='xhigh' WHERE operation_id=101",
        };
    }
};

pub fn timingSource(values: *@import("../model_timing.zig").Values) @import("../model_timing.zig").Source {
    return .{ .context = values, .read = struct {
        fn read(raw: *anyopaque, _: u64, _: std.Io) @import("../model_timing.zig").Values {
            return @as(*@import("../model_timing.zig").Values, @ptrCast(@alignCast(raw))).*;
        }
    }.read };
}

pub fn settleModelFailureWithTimings(storage: *Store, binding: AttemptBinding, failure: @import("domain/model_settlement.zig").ModelFailure, disposition: @import("domain/model_settlement.zig").ModelFailureClass, timings: @import("../model_timing.zig").Values, faults: @import("Store.zig").Faults) !void {
    var values = timings;
    const original = storage.modelTimingSource().*;
    storage.modelTimingSource().* = timingSource(&values);
    defer storage.modelTimingSource().* = original;
    return storage.settleModelAttemptFailure(binding, failure, disposition, faults);
}
