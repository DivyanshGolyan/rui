//! Store fixtures that tests outside src/store/ use too: a configured Session,
//! a submitted message, a settled answer and a settled compaction. Also the
//! engine seam of the Store's conformance tests (`forEachEngine`), and the
//! fixtures they arrange and read rows through.

const std = @import("std");
const platform = @import("../platform.zig");
const tool_catalog = @import("../tools.zig");
const named_scratch = @import("../named_scratch.zig");
const protocol = @import("../protocol.zig");
const output_format = @import("../output_format.zig");
const output_decode = @import("../output_decode.zig");
const store_core = @import("Store.zig");
const rsql = @import("rsql.zig");
const sqlite = @import("sqlite.zig");
const mysql_testing = @import("mysql_testing.zig");
const mysql_dialect_check = @import("mysql_dialect_check.zig");
const required_engines = @import("wire/required_engines.zig");
const Store = store_core.Store;
const historical_domain = @import("domain/historical.zig");
const model_settlement_domain = @import("domain/model_settlement.zig");
const AttemptBinding = store_core.AttemptBinding;
const OutputItemKind = historical_domain.OutputItemKind;
const ValidatedOutput = model_settlement_domain.ValidatedOutput;

pub const OutputMetadataWriter = output_format.OutputMetadataWriter;

/// The engines a conformance test runs on, each in this one process.
pub const Engine = enum { sqlite, mysql };

/// One run of a conformance test's body, on one engine.
pub const Case = struct {
    engine: Engine,
};

pub const EngineName = required_engines.EngineName;
pub const parseRequiredEngines = required_engines.parse;

/// The names `RUI_TEST_REQUIRE_ENGINES` lists, parsed once per process;
/// none when it is unset.
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

/// Engines reached outside Store conformance: Postgres wire tests.
pub const checked_elsewhere: std.EnumSet(EngineName) = .initMany(&.{.postgres});

/// The first of `names` that no test reaches, neither an `Engine` nor
/// one of `elsewhere`, or null.
pub fn unbuiltEngine(names: std.EnumSet(EngineName), elsewhere: std.EnumSet(EngineName)) ?EngineName {
    var listed = names.iterator();
    while (listed.next()) |name| {
        if (elsewhere.contains(name)) continue;
        if (std.meta.stringToEnum(Engine, @tagName(name)) == null) return name;
    }
    return null;
}

/// Runs `run(case)` once for each `Engine`, in order, and on a failure
/// prints the engine's name and returns the error. It first checks
/// `requiredEngines`: an unknown name, or a listed engine no test reaches
/// (`unbuiltEngine`), fails every conformance test.
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
            if (engine == .mysql) mysql_dialect_check.conformancePassed();
        }
    }
}

/// Opens `storage` on `case`'s engine for the directory `tmp`, so opening
/// the same `tmp` again reopens the same Store. On SQLite the database is
/// the file store.sqlite3 in `tmp`.
pub fn testingStore(case: *const Case, storage: *Store, tmp: *std.testing.TmpDir, io: std.Io) !void {
    return testingStoreWith(case, storage, tmp, io, .{});
}

/// How `testingStoreWith` opens a Store beyond `testingStore`'s defaults.
pub const TestingStoreOptions = struct {
    /// The tools the Host offers.
    catalog: *const tool_catalog.Catalog = &tool_catalog.built_in,
    /// The canonical identity the Store is opened under, when not `tmp`'s
    /// real path.
    identity: ?[]const u8 = null,
    /// The providers whose Sessions get model Attempts.
    served: protocol.Routes = protocol.routesAll(.endpoint),
};

/// `testingStore` with `options`.
pub fn testingStoreWith(case: *const Case, storage: *Store, tmp: *std.testing.TmpDir, io: std.Io, options: TestingStoreOptions) !void {
    switch (case.engine) {
        .mysql => return mysql_testing.open(storage, tmp, io, options),
        .sqlite => {
            var root_buffer: [protocol.max_store_bytes]u8 = undefined;
            const root_length = try tmp.dir.realPath(io, &root_buffer);
            const root = root_buffer[0..root_length];
            var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
            const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
            return storage.openWithOptions(io, database, options.identity orelse root, .{ .served = options.served, .catalog = options.catalog }) catch |err| {
                std.debug.print("testing Store open failed: {s}\n", .{@errorName(err)});
                return err;
            };
        },
    }
}

/// Words a fixture's SQL may not hold outside string literals, matched
/// whole and ignoring case: each names a SQLite setting, schema change,
/// transaction or connection mechanism. A test that needs one belongs in
/// sqlite_tests.zig. tests/ci/store_conformance.py reads this list.
pub const fixture_sqlite_words = [_][]const u8{
    "PRAGMA", "temp",      "CREATE", "ALTER",  "DROP",     "TRIGGER", "VIEW",
    "ATTACH", "SAVEPOINT", "BEGIN",  "COMMIT", "ROLLBACK", "VACUUM",
};

/// Word prefixes a fixture's SQL may not hold outside string literals,
/// ignoring case: SQLite's own tables (`sqlite_schema`) and its PRAGMA
/// table functions (`pragma_table_info()`). tests/ci/store_conformance.py
/// reads this list.
pub const fixture_sqlite_prefixes = [_][]const u8{ "sqlite_", "pragma_" };

/// Why `text` cannot be a fixture's SQL, or null: it fails
/// `rsql.portabilityError`; or, outside its string literals, it holds a
/// word of `fixture_sqlite_words`, a word starting with one of
/// `fixture_sqlite_prefixes`, or `AS TEXT` (MySQL casts only to CHAR).
/// It does not check that `text` parses.
pub fn fixtureTextError(comptime text: []const u8) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(1000 * text.len + 10000);
        if (rsql.portabilityError(text, rsql.reserved_names_checked)) |message| return message;
        var index: usize = 0;
        var previous: []const u8 = "";
        while (index < text.len) {
            if (text[index] == '\'') {
                // A literal ends at a quote not doubled.
                index += 1;
                while (index < text.len) : (index += 1) {
                    if (text[index] != '\'') continue;
                    if (index + 1 < text.len and text[index + 1] == '\'') {
                        index += 1;
                        continue;
                    }
                    break;
                }
                index += 1;
                previous = "";
                continue;
            }
            if (!isWordByte(text[index])) {
                if (!std.ascii.isWhitespace(text[index])) previous = "";
                index += 1;
                continue;
            }
            var end = index;
            while (end < text.len and isWordByte(text[end])) end += 1;
            const word = text[index..end];
            index = end;
            for (fixture_sqlite_words) |sqlite_word| {
                if (std.ascii.eqlIgnoreCase(word, sqlite_word)) return "fixture: '" ++ word ++ "' is a SQLite mechanism; write the test in sqlite_tests.zig";
            }
            for (fixture_sqlite_prefixes) |prefix| {
                if (std.ascii.startsWithIgnoreCase(word, prefix)) return "fixture: '" ++ word ++ "' is a SQLite mechanism; write the test in sqlite_tests.zig";
            }
            if (std.ascii.eqlIgnoreCase(previous, "AS") and std.ascii.eqlIgnoreCase(word, "TEXT"))
                return "fixture: 'AS TEXT' is not a MySQL cast; compare the bytes another way";
            previous = word;
        }
        return null;
    }
}

/// The Store at `schema.migration_baseline`, which the migration tests of
/// each engine move to the current schema: its DDL as SQLite and MySQL ran
/// it then, and rows a Store at the baseline held, written as fixture text
/// for both engines. They never change; `schema.migrations` grows instead.
pub const baseline_sqlite_ddl: [:0]const u8 = @embedFile("migration_baseline.sqlite.sql");
pub const baseline_mysql_ddl: [:0]const u8 = @embedFile("migration_baseline.mysql.sql");
pub const baseline_rows: [:0]const u8 = @embedFile("migration_baseline_rows.sql");
/// The rows a Store at the current schema holds once every migration ran
/// on `baseline_rows`: the oracle each engine's migration test compares a
/// migrated Store with. Written by hand from what each step should do, never
/// read back from a migrated Store; each format change edits it, and its
/// diff against `baseline_rows` shows every row the chain changes.
pub const expected_rows: [:0]const u8 = @embedFile("migration_expected_rows.sql");
/// `expected_rows` on MySQL, whose content rows hold no payload: its
/// first statement, the content rows, gives way to
/// migration_expected_content.mysql.sql's content and content_chunk rows.
pub const expected_mysql_rows: [:0]const u8 = blk: {
    @setEvalBranchQuota(4 * expected_rows.len);
    const first = std.mem.indexOf(u8, expected_rows, ";\n").? + 2;
    if (!std.mem.startsWith(u8, expected_rows, "INSERT INTO content(")) @compileError("migration_expected_rows.sql starts with the content rows");
    break :blk @embedFile("migration_expected_content.mysql.sql") ++ expected_rows[first..];
};
comptime {
    if (fixtureTextError(baseline_rows)) |message| @compileError("migration_baseline_rows.sql: " ++ message);
    if (fixtureTextError(expected_rows)) |message| @compileError("migration_expected_rows.sql: " ++ message);
    if (fixtureTextError(expected_mysql_rows)) |message| @compileError("migration_expected_content.mysql.sql: " ++ message);
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Texts `fixtureTextError` refuses or takes, one of each rule and of
/// each way past it. A test checks each verdict, and
/// tests/ci/store_conformance.py reads these to check its own verdicts
/// agree.
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

/// `text` when it passes `fixtureTextError`, else a failed build. Each
/// call also hands its MySQL spelling to the live MySQL check
/// (`mysql_dialect_check.shadowPrepareFixture`).
fn fixtureText(comptime text: [:0]const u8) [:0]const u8 {
    if (comptime fixtureTextError(text)) |message| @compileError(message ++ ": " ++ text);
    switch (comptime rsql.mysqlRendering(text)) {
        .refused => |message| @compileError("fixture: MySQL rendering refuses it: " ++ message ++ ": " ++ text),
        .rendered => {},
    }
    mysql_dialect_check.shadowPrepareFixture(text);
    return text;
}

/// Runs `sql` on `storage`'s SQLite database outside any entry point, so no entry
/// point touches what it changes. With empty `args`, `sql` may hold several
/// statements; otherwise it is one statement whose `?1`, `?2`... take
/// `args` in order: integers, `Blob`s as blobs, and byte slices as text.
/// MySQL fixtures use the root connection; application grants stay restricted.
pub fn exec(storage: *Store, comptime sql: [:0]const u8, args: anytype) !void {
    _ = fixtureText(sql);
    if (storage.engine == .mysql) return mysql_testing.exec(storage, sql, args);
    return sqliteExec(storage.sqliteDatabase(), sql, args);
}

/// Seeds a loaded subset for visibility tests before find_tools exists.
/// `source` supplies its configured set; `session` and all its revisions
/// load that set. Only fixtures bypass configure's reachability check.
pub fn setLoadedToolsForTesting(storage: *Store, session: []const u8, source: []const u8) !void {
    // MySQL refuses an UPDATE that reads its own target table, so read first.
    const set = try queryU64(storage, "SELECT tool_set_id FROM session WHERE session_ref=?1", .{source});
    try exec(storage, "UPDATE session SET loaded_tool_set_id=?1 WHERE session_ref=?2", .{ set, session });
    try exec(storage, "UPDATE session_revision SET loaded_tool_set_id=(SELECT loaded_tool_set_id FROM session WHERE session_ref=?1) WHERE session_ref=?1", .{session});
}

/// The first column of `sql`'s first row: `QueryFailed` with no row, and
/// `CorruptStore` when it is negative. `args` binds as in `exec`.
pub fn queryU64(storage: *Store, comptime sql: [:0]const u8, args: anytype) !u64 {
    _ = fixtureText(sql);
    if (storage.engine == .mysql) return mysql_testing.queryU64(storage, sql, args);
    return sqliteQueryU64(storage.sqliteDatabase(), sql, args);
}

/// `exec` on a SQLite connection, for any SQLite text: sqlite_tests.zig's
/// raw SQL.
pub fn sqliteExec(database: *sqlite.c.sqlite3, sql: [:0]const u8, args: anytype) !void {
    if (args.len == 0) return sqlite.exec(database, sql);
    const statement = try sqlite.prepare(database, sql);
    defer _ = sqlite.c.sqlite3_finalize(statement);
    try bindFixtureArgs(statement, args);
    try sqlite.expectDone(statement);
}

/// `queryU64` on a SQLite connection, for any SQLite text:
/// sqlite_tests.zig's raw SQL.
pub fn sqliteQueryU64(database: *sqlite.c.sqlite3, sql: [:0]const u8, args: anytype) !u64 {
    const statement = try sqlite.prepare(database, sql);
    defer _ = sqlite.c.sqlite3_finalize(statement);
    try bindFixtureArgs(statement, args);
    if (sqlite.c.sqlite3_step(statement) != sqlite.c.SQLITE_ROW) return error.QueryFailed;
    const value = sqlite.c.sqlite3_column_int64(statement, 0);
    if (value < 0) return error.CorruptStore;
    return @intCast(value);
}

/// Zeroes the bytes of each content row whose id `ids`, a SELECT,
/// returns, keeping their lengths: SQLite's payload, and in the MySQL
/// check's spelling the rows' chunks (`schema` content_chunk).
pub fn zeroContent(storage: *Store, comptime ids: [:0]const u8) !void {
    _ = fixtureText("UPDATE content_chunk SET bytes=zeroblob(length(bytes)) WHERE content_id IN (" ++ ids ++ ")");
    const sql = "UPDATE content SET payload=zeroblob(byte_length) WHERE content_id IN (" ++ ids ++ ")";
    if (comptime fixtureTextError(sql)) |message| @compileError(message ++ ": " ++ sql);
    if (storage.engine == .mysql) return mysql_testing.exec(storage, "UPDATE content_chunk SET bytes=zeroblob(length(bytes)) WHERE content_id IN (" ++ ids ++ ")", .{});
    return sqliteExec(storage.sqliteDatabase(), sql, .{});
}

/// `exec` with foreign keys unchecked for `sql` alone, restored on failure.
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

/// The same fixtures for tests that run only on SQLite
/// (sqlite_tests.zig): `sql` is SQLite's text, held to no portability
/// rule and never handed to the live MySQL check.
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

/// Leaves `table` preparing normally but failing at the first step of a
/// statement that reads it, the shape of an I/O or corruption fault after
/// a statement compiled: a renamed table and an overflowing view.
pub fn failReadsOf(storage: *Store, comptime table: []const u8) !void {
    if (storage.engine == .mysql) return mysql_testing.rawExec(storage, "RENAME TABLE " ++ table ++ " TO " ++ table ++ "_unreadable;CREATE VIEW " ++ table ++ " AS SELECT * FROM " ++ table ++ "_unreadable WHERE abs(-9223372036854775808) IS NOT NULL");
    try sqlite.exec(storage.sqliteDatabase(), "ALTER TABLE " ++ table ++ " RENAME TO " ++ table ++ "_unreadable");
    try sqlite.exec(storage.sqliteDatabase(), "CREATE VIEW " ++ table ++ " AS SELECT * FROM " ++ table ++ "_unreadable " ++
        "WHERE abs(-9223372036854775808) IS NOT NULL");
}

/// Bytes a fixture binds as a blob, not as text.
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

pub fn completeConfiguration(key: []const u8, session_ref: []const u8, workspace: []const u8, model: []const u8) !protocol.ConfigureCommand {
    var command: protocol.ConfigureCommand = .{};
    try command.key.set(key);
    try command.session.set(session_ref);
    command.configuration.workspace.state = .value;
    try command.configuration.workspace.value.set(workspace);
    command.configuration.provider.state = .value;
    try command.configuration.provider.value.set("codex");
    command.configuration.model.state = .value;
    try command.configuration.model.value.set(model);
    return command;
}

pub fn completeMessage(
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
    const reply = storage.configure(&command, .{});
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

/// One Turn: a message named by `name`, its admission and an answer of `parts`.
pub fn answerTestTurn(
    storage: *Store,
    tmp: *std.testing.TmpDir,
    session: []const u8,
    comptime name: []const u8,
    parts: []const TestingAnswerPart,
) !void {
    try submitTestMessage(storage, tmp, name ++ "-input", name ++ "-key", session, "input");
    const binding = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    // A real message item whose output_text blocks hold the parts.
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

/// Gives compaction Operation `operation` the floor at the position of
/// the conversation entry of its Session whose text is `text`, at `level`,
/// as admission would for a compaction that makes room (D217).
pub fn setHistoryFloorForTesting(storage: *Store, operation: u64, text: []const u8, level: u64) !void {
    if (!@import("builtin").is_test) @compileError("test-only Store fixture");
    const digest = protocol.contentDigest(text);
    try exec(storage, "UPDATE model_operation SET history_floor=(SELECT e.session_position FROM conversation_entry e JOIN content c ON c.content_id=e.content_id " ++
        "WHERE e.session_ref=model_operation.session_ref AND c.digest=?2 AND c.private=0),history_level=?3,history_dropped=0 WHERE operation_id=?1", .{ operation, Blob{ .bytes = &digest }, level });
}

/// Whether Turn `turn` ended with `outcome`.
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
        // Each item is judged under the Operation that accepts its kind, so
        // the Store's own Operation check is what rejects a misplaced item.
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
        // Deliberately present: compaction must not project visible messages.
        .answer_length = if (try storage.modelOperationKind(binding) == .compaction) 6 else 0,
        .answer_digest = protocol.contentDigest("answer"),
        .response_id = .{},
        .model_evidence = testing_absent_model_evidence,
        .request_id = .{},
    }, .{});
}

/// Settles `binding` with `items`, raw provider items judged in order, of
/// which the last message's whole text is `answer`; its function calls
/// count as the output's calls.
pub fn settleItemsForTesting(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, items: []const []const u8, answer: []const u8) !void {
    return settleSelectedItemsForTesting(storage, tmp, binding, items, null, answer);
}

/// `settleItemsForTesting` with the answer the message at `selected`, when
/// given, as phase selection picks one before later messages.
pub fn settleSelectedItemsForTesting(storage: *Store, tmp: *std.testing.TmpDir, binding: AttemptBinding, items: []const []const u8, selected: ?u64, answer: []const u8) !void {
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

/// Counts the content rows besides those only tool records name: every
/// Session saves its tool set's texts once, beside what a test imports,
/// and a Session's instructions may share one of them (the empty text).
pub const content_beside_tools = "SELECT count(*) FROM content WHERE (content_id NOT IN (SELECT description_content_id FROM tool_record) " ++
    "AND content_id NOT IN (SELECT input_schema_content_id FROM tool_record)) OR content_id IN (SELECT instructions_content_id FROM session_revision) " ++
    "OR content_id IN (SELECT output_schema_content_id FROM session_revision WHERE output_schema_content_id IS NOT NULL)";
