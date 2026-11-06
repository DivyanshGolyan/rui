//! The live check of the Store's MySQL spelling against a MySQL 8.4 server,
//! in test builds only. One root connection per test process, over the Unix
//! socket `RUI_TEST_MYSQL_SOCKET` with `RUI_TEST_MYSQL_ROOT_PASSWORD`, opens
//! on first use. It creates the database `rui_dialect_check`, sets
//! `schema.mysql_session`, runs every `schema.objects(.mysql)` statement,
//! and creates the touch oracle's MySQL triggers over a table in the sibling
//! database `rui_dialect_check_oracle`. Then `shadowPrepare` PREPAREs, on
//! that database, each statement text the test run hands it.
//!
//! Without both variables the check does nothing and its test skips, unless
//! `RUI_TEST_REQUIRE_ENGINES` lists `mysql`; then its test fails.
//!
//! With `RUI_TEST_MYSQL_RECORD` set, the check rewrites that file after each
//! thing it does: the DDL statements it ran, the PREPAREs it issued, and the
//! probes MySQL refused as expected, and the migration tests that passed.
//! CI fails a shard whose record is missing, counts no PREPARE or no
//! passed migration test (`tests/integration/live_engines.py`), so
//! any path that keeps the check from running turns red.
//!
//! PREPARE resolves names, types and grammar; it binds no value and runs
//! nothing, so literal typing, guards, row counts, transactions and query
//! plans are not checked here.
const std = @import("std");
const protocol = @import("../protocol.zig");
const rsql = @import("rsql.zig");
const schema = @import("schema.zig");
const sqlite = @import("sqlite.zig");
const store_testing = @import("testing.zig");
const mysql_connection = @import("wire/mysql_connection.zig");
const mysql = mysql_connection.mysql;

const database = "rui_dialect_check";
const oracle_database = "rui_dialect_check_oracle";

const State = enum { unopened, absent, open, broken };

/// Guards everything below: some Store tests call the Store from threads.
var mutex: std.Io.Mutex = .init;
var state: State = .unopened;
var driver: mysql_connection.Connection = undefined;
/// Each statement the opening's DDL had refused, with MySQL's error, one
/// per line; the DDL test reports them.
var ddl_refusals: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
var socket_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
var password_buffer: [mysql.max_password_bytes]u8 = undefined;
var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
/// The file `RUI_TEST_MYSQL_RECORD` names, or null.
var record_path: ?[]const u8 = null;
/// What the check did in this process, as the record states it.
var done: struct {
    ddl: u32 = 0,
    ddl_refused: u32 = 0,
    prepares: u32 = 0,
    prepare_refused: u32 = 0,
    probes: u32 = 0,
    /// Migration tests whose migrated database matched a fresh one.
    migrations: u32 = 0,
    conformance: u32 = 0,

    pub fn format(counts: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("ddl={d} ddl_refused={d} prepares={d} prepare_refused={d} probes={d} migrations={d} conformance={d}\n", .{
            counts.ddl, counts.ddl_refused, counts.prepares, counts.prepare_refused, counts.probes, counts.migrations, counts.conformance,
        });
    }
} = .{};

pub const Config = struct { socket: []const u8, password: []const u8, record: ?[]const u8 };

/// The server the environment names, copied out of it; null when it names
/// none. `error.MysqlRequired` when `RUI_TEST_REQUIRE_ENGINES` lists `mysql`
/// and either variable is missing, or when only one of them is set.
fn configured() !?Config {
    var environ = try std.testing.environ.createMap(std.heap.page_allocator);
    defer environ.deinit();
    const socket = environ.get("RUI_TEST_MYSQL_SOCKET");
    const password = environ.get("RUI_TEST_MYSQL_ROOT_PASSWORD");
    if (socket == null and password == null and !(try store_testing.requiredEngines()).contains(.mysql)) return null;
    if (socket == null or password == null) return error.MysqlRequired;
    if (socket.?.len > socket_buffer.len or password.?.len > password_buffer.len) return error.MysqlConfigTooLong;
    @memcpy(socket_buffer[0..socket.?.len], socket.?);
    @memcpy(password_buffer[0..password.?.len], password.?);
    const record = environ.get("RUI_TEST_MYSQL_RECORD");
    if (record) |path| {
        if (path.len > record_buffer.len) return error.MysqlConfigTooLong;
        @memcpy(record_buffer[0..path.len], path);
    }
    return .{
        .socket = socket_buffer[0..socket.?.len],
        .password = password_buffer[0..password.?.len],
        .record = if (record) |path| record_buffer[0..path.len] else null,
    };
}

/// `configured`, under `mutex`, for another live test that opens its own
/// connection to the same server.
pub fn rootConfig() !?Config {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return configured();
}

/// Under `mutex`: rewrites the record file with `done`, when one is named.
/// A failed write logs at err level, so a run that cannot record fails.
fn writeRecord() void {
    const path = record_path orelse return;
    var line: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "{f}", .{done}) catch unreachable;
    const io = std.testing.io;
    const file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch |err|
        return std.log.err("MySQL dialect check: cannot write the record {s}: {s}", .{ path, @errorName(err) });
    defer file.close(io);
    file.writeStreamingAll(io, text) catch |err|
        std.log.err("MySQL dialect check: cannot write the record {s}: {s}", .{ path, @errorName(err) });
}

/// Under `mutex`: the bootstrapped connection, or null when MySQL is not
/// configured or the opening failed. The first call opens it; a failed
/// opening logs at err level, which fails the test that made the call.
fn connection() ?*mysql_connection.Connection {
    switch (state) {
        .open => return &driver,
        .absent, .broken => return null,
        .unopened => {},
    }
    state = .broken;
    const config = configured() catch |err| {
        std.log.err("MySQL dialect check: {s}", .{@errorName(err)});
        return null;
    } orelse {
        state = .absent;
        return null;
    };
    var refusal: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer refusal.deinit();
    driver.open(.{ .address = .{ .unix_socket = config.socket }, .user = "root", .password = config.password, .database = "mysql" }, &refusal.writer) catch |err| {
        std.log.err("MySQL dialect check: root login over {s} failed: {s} {s}", .{ config.socket, @errorName(err), refusal.written() });
        return null;
    };
    bootstrap() catch |err| {
        std.log.err("MySQL dialect check: bootstrap failed: {s}", .{@errorName(err)});
        return null;
    };
    state = .open;
    record_path = config.record;
    writeRecord();
    return &driver;
}

/// The fresh databases, the session settings, then each schema object and
/// oracle statement on its own, so a refused one does not hide the next.
fn bootstrap() !void {
    try setup("DROP DATABASE IF EXISTS " ++ database ++ ";DROP DATABASE IF EXISTS " ++ oracle_database ++
        ";CREATE DATABASE " ++ database ++ ";CREATE DATABASE " ++ oracle_database ++ ";USE " ++ database);
    for (schema.mysql_session) |text| try setup(text);
    const objects = comptime schema.objects(.mysql);
    for (objects) |object| try ddl(object.name, object.sql);
    try ddl("touch oracle", "CREATE TABLE " ++ oracle_database ++ ".touched_oracle(session_ref TEXT)");
    const triggers = comptime sqlite.touchOracleTriggers(.mysql, oracle_database ++ ".touched_oracle");
    for (triggers) |text| try ddl("touch oracle", text);
}

fn setup(text: []const u8) !void {
    if (try run(text)) |refused| {
        std.log.err("MySQL dialect check: MySQL refused {s}: {f}", .{ text, refused });
        return error.MysqlRefusedSetup;
    }
}

fn ddl(name: []const u8, text: []const u8) !void {
    done.ddl += 1;
    if (try run(text)) |refused| {
        done.ddl_refused += 1;
        try ddl_refusals.writer.print("{s}: {f}\n  {s}\n", .{ name, refused, text });
    }
}

const Refused = struct {
    code: u16,
    message: [480]u8,
    message_len: usize,

    pub fn format(refused: *const Refused, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("err {d} {s}", .{ refused.code, refused.message[0..refused.message_len] });
    }
};

/// Runs `text` and returns the first statement refusal of its results.
fn run(text: []const u8) !?Refused {
    try driver.query(text);
    var refused: ?Refused = null;
    while (!driver.isReady()) switch (try driver.next()) {
        .err => |err| if (refused == null) {
            const len = @min(err.message.len, 480);
            refused = .{ .code = err.code, .message = undefined, .message_len = len };
            @memcpy(refused.?.message[0..len], err.message[0..len]);
        },
        else => {},
    };
    return refused;
}

/// PREPAREs `text` on the check's database and DEALLOCATEs it, once per
/// text per process, when MySQL is configured. A refusal logs the text and
/// MySQL's error at err level. That fails the running test without stopping
/// it, so one run reports every refused text the run reaches. A later test
/// that reaches the same text is not failed again.
pub fn shadowPrepare(comptime text: []const u8) void {
    once(text, null);
}

/// Fixture text in MySQL's spelling, through `shadowPrepare` one statement
/// at a time. Text MySQL rendering refuses is reported like a refused
/// PREPARE, once and only while MySQL is configured, so the build still
/// passes where the check does not run.
pub fn shadowPrepareFixture(comptime text: []const u8) void {
    switch (comptime rsql.mysqlRendering(text)) {
        .refused => |message| once(text, message),
        .rendered => |template| inline for (comptime statements(template.prepared())) |statement| once(statement, null),
    }
}

/// `shadowPrepare`, or with `unrendered` set, the report of MySQL
/// rendering's refusal of `text` in its place.
fn once(comptime text: []const u8, comptime unrendered: ?[]const u8) void {
    if (!@import("builtin").is_test) @compileError("test-only check");
    const Seen = Once(text);
    if (Seen.done.load(.acquire)) return;
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (Seen.done.load(.monotonic)) return;
    Seen.done.store(true, .release);
    _ = connection() orelse return;
    if (unrendered) |message| return std.log.err("{s}\n  {s}", .{ message, text });
    const refused = run(comptime prepareQuery(text)) catch |err| {
        state = .broken;
        std.log.err("MySQL dialect check: connection failed: {s}", .{@errorName(err)});
        return;
    };
    done.prepares += 1;
    if (refused != null) done.prepare_refused += 1;
    writeRecord();
    std.log.err("MySQL 8.4 refused to PREPARE: {f}\n  {s}", .{ refused orelse return, text });
}

/// The flag that `text` was checked in this process. The struct names
/// `text`, so each text gets its own type and flag: a struct that names
/// no comptime value is one type however often it is instantiated.
fn Once(comptime text: []const u8) type {
    return struct {
        const key = text;
        var done: std.atomic.Value(bool) = .init(false);
    };
}

/// `PREPARE ... FROM` `text` as a string literal, then DEALLOCATE. MySQL
/// stops a multi-statement query at its first error, so a refused PREPARE
/// leaves nothing to deallocate. Quotes double; `schema.mysql_session` sets
/// NO_BACKSLASH_ESCAPES, so a backslash is an ordinary character.
fn prepareQuery(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10 * text.len + 1000);
        var quoted: []const u8 = "";
        for (text) |byte| quoted = quoted ++ (if (byte == '\'') "''" else &[_]u8{byte});
        return "PREPARE rui_dialect_check FROM '" ++ quoted ++ "';DEALLOCATE PREPARE rui_dialect_check";
    }
}

/// `text` split at each semicolon outside a string literal, each piece
/// trimmed, empty pieces dropped.
fn statements(comptime text: []const u8) []const []const u8 {
    comptime {
        @setEvalBranchQuota(10 * text.len + 1000);
        var result: []const []const u8 = &.{};
        var start = 0;
        var quoted = false;
        for (text, 0..) |byte, index| {
            if (byte == '\'') quoted = !quoted;
            if (byte != ';' or quoted) continue;
            result = result ++ piece(text[start..index]);
            start = index + 1;
        }
        return result ++ piece(text[start..]);
    }
}

fn piece(comptime text: []const u8) []const []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\n");
    return if (trimmed.len == 0) &.{} else &.{trimmed};
}

test "each text has its own checked flag" {
    try std.testing.expect(&Once("SELECT 1").done != &Once("SELECT 2").done);
    try std.testing.expect(&Once("SELECT 1").done == &Once("SELECT 1").done);
}

test "fixture text splits at semicolons outside string literals, and PREPARE quotes it whole" {
    const pieces = comptime statements("DELETE FROM turn; INSERT INTO t VALUES('a;b','it''s;');\n");
    try std.testing.expectEqual(2, pieces.len);
    try std.testing.expectEqualStrings("DELETE FROM turn", pieces[0]);
    try std.testing.expectEqualStrings("INSERT INTO t VALUES('a;b','it''s;')", pieces[1]);
    try std.testing.expectEqualStrings("PREPARE rui_dialect_check FROM 'SELECT ''it''''s''';DEALLOCATE PREPARE rui_dialect_check", comptime prepareQuery("SELECT 'it''s'"));
}

test "the schema's MySQL DDL and the touch oracle's MySQL triggers run on MySQL 8.4" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    if (ddl_refusals.written().len != 0) {
        std.log.err("MySQL 8.4 refused the schema's DDL:\n{s}", .{ddl_refusals.written()});
        return error.MysqlRefusedDdl;
    }
}

test "PREPARE on the check's database refuses what MySQL 8.4 refuses" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    const probes = [_]struct { code: u16, text: []const u8 }{
        .{ .code = 1054, .text = "SELECT no_such_column FROM turn" },
        .{ .code = 1093, .text = "UPDATE turn SET outcome_at=(SELECT max(outcome_at) FROM turn)" },
        .{ .code = 1055, .text = "SELECT session_ref, turn_id FROM turn GROUP BY session_ref" },
        .{ .code = 1235, .text = "SELECT turn_id FROM turn WHERE turn_id IN (SELECT turn_id FROM turn LIMIT 1)" },
    };
    inline for (probes) |probe| {
        const refused = try run(comptime prepareQuery(probe.text)) orelse {
            std.debug.print("MySQL 8.4 prepared {s}\n", .{probe.text});
            return error.ProbePrepared;
        };
        std.testing.expectEqual(probe.code, refused.code) catch |err| {
            std.debug.print("{s}: {f}\n", .{ probe.text, refused });
            return err;
        };
        done.probes += 1;
    }
    writeRecord();
}

const migrated_database = "rui_migration_migrated";
const fresh_database = "rui_migration_fresh";

/// Runs `text` on `name`, with foreign keys unchecked when `unchecked`;
/// a refusal logs and fails.
fn load(comptime name: []const u8, text: []const u8, unchecked: bool) !void {
    try setup("USE " ++ name);
    if (unchecked) try setup("SET FOREIGN_KEY_CHECKS=0");
    defer if (unchecked) setup("SET FOREIGN_KEY_CHECKS=1") catch {};
    if (try run(text)) |refused| {
        std.log.err("MySQL migration check: {s} refused: {f}", .{ name, refused });
        return error.MysqlRefusedMigration;
    }
}

/// `text`'s rows: a line per row, each value as its length and bytes.
fn writeResult(text: []const u8, out: *std.Io.Writer) !void {
    try driver.query(text);
    var refused = false;
    while (!driver.isReady()) switch (try driver.next()) {
        .err => |err| {
            std.log.err("MySQL migration check: err {d} {s}\n  {s}", .{ err.code, err.message, text });
            refused = true;
        },
        .row => try out.writeByte('\n'),
        .value => |length| if (length) |bytes| try out.print(" {d}:", .{bytes}) else try out.writeAll(" null"),
        .bytes => |bytes| try out.writeAll(bytes),
        else => {},
    };
    if (refused) return error.MysqlRefusedQuery;
}

/// What information_schema says of database `name`'s tables, columns,
/// indexes, CHECKs and foreign keys, without the names MySQL generates for
/// CHECKs and foreign keys.
fn shapeQueries(comptime name: []const u8) [5][]const u8 {
    const in = " WHERE TABLE_SCHEMA='" ++ name ++ "'";
    return .{
        "SELECT TABLE_NAME,ENGINE,TABLE_COLLATION,CREATE_OPTIONS FROM information_schema.TABLES" ++ in ++ " ORDER BY TABLE_NAME",
        "SELECT TABLE_NAME,ORDINAL_POSITION,COLUMN_NAME,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,COLLATION_NAME,EXTRA FROM information_schema.COLUMNS" ++ in ++ " ORDER BY TABLE_NAME,ORDINAL_POSITION",
        "SELECT TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX,COLUMN_NAME,NON_UNIQUE,COLLATION,SUB_PART,EXPRESSION FROM information_schema.STATISTICS" ++ in ++ " ORDER BY TABLE_NAME,INDEX_NAME,SEQ_IN_INDEX",
        "SELECT t.TABLE_NAME,k.CHECK_CLAUSE FROM information_schema.TABLE_CONSTRAINTS t JOIN information_schema.CHECK_CONSTRAINTS k " ++
            "ON k.CONSTRAINT_SCHEMA=t.CONSTRAINT_SCHEMA AND k.CONSTRAINT_NAME=t.CONSTRAINT_NAME WHERE t.CONSTRAINT_SCHEMA='" ++ name ++ "' AND t.CONSTRAINT_TYPE='CHECK' ORDER BY 1,2",
        "SELECT TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,REFERENCED_TABLE_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE" ++ in ++
            " AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY 1,2,3,4,5",
    };
}

/// Each MySQL table's rows in database `name`, in key order.
fn rowQueries(comptime name: []const u8) []const []const u8 {
    var queries: []const []const u8 = &.{};
    for (schema.tables) |table| if (table.engines.on(.mysql)) {
        var order: []const u8 = "";
        for (table.primary_key, 0..) |column, position| order = order ++ (if (position == 0) "" else ",") ++ column;
        queries = queries ++ .{"SELECT * FROM " ++ name ++ "." ++ table.name ++ " ORDER BY " ++ order};
    };
    return queries;
}

/// Fails unless database `name`'s catalog (`schema.catalogSql`) has the
/// digest the schema derives, and then logs the lines each side lacks.
fn expectCatalog(comptime name: []const u8) !void {
    var lines: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lines.deinit();
    try writeResult(comptime schema.catalogSql("'" ++ name ++ "'"), &lines.writer);
    // writeResult writes a row as its end of line, then each value as " length:" and its bytes.
    var sum: u64 = 0;
    var rows = std.mem.splitScalar(u8, lines.written(), '\n');
    while (rows.next()) |row| {
        if (row.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, row, ':') orelse return error.MysqlCatalogRow;
        sum +%= schema.catalogLineDigest(row[colon + 1 ..]);
    }
    if (sum == schema.catalogDigest()) return;
    // stderr, which the test runner always shows.
    const expected = comptime schema.catalogLinesForTesting();
    rows = std.mem.splitScalar(u8, lines.written(), '\n');
    while (rows.next()) |row| {
        if (row.len == 0) continue;
        const line = row[std.mem.indexOfScalar(u8, row, ':').? + 1 ..];
        for (expected) |want| {
            if (std.mem.eql(u8, want, line)) break;
        } else std.debug.print("MySQL catalog check: only {s} has: {s}\n", .{ name, line });
    }
    for (expected) |want| {
        rows = std.mem.splitScalar(u8, lines.written(), '\n');
        while (rows.next()) |row| {
            const colon = std.mem.indexOfScalar(u8, row, ':') orelse continue;
            if (std.mem.eql(u8, row[colon + 1 ..], want)) break;
        } else std.debug.print("MySQL catalog check: only the schema has, for {s}: {s}\n", .{ name, want });
    }
    return error.MysqlCatalogDiffers;
}

/// Writes each query of `migrated` and its twin of `fresh`, and fails
/// on the first pair that differs.
fn expectSameResults(comptime migrated: []const []const u8, comptime fresh: []const []const u8) !void {
    inline for (migrated, fresh) |left, right| {
        var left_result: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer left_result.deinit();
        var right_result: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer right_result.deinit();
        try writeResult(left, &left_result.writer);
        try writeResult(right, &right_result.writer);
        std.testing.expectEqualStrings(right_result.written(), left_result.written()) catch |err| {
            std.log.err("MySQL migration check: a migrated Store differs from a fresh one at\n  {s}", .{left});
            return err;
        };
    }
}

test "a MySQL Store at the migration baseline with its rows takes every migration to the current schema's shape and rows" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer setup("USE " ++ database) catch {};
    try setup("DROP DATABASE IF EXISTS " ++ migrated_database ++ ";DROP DATABASE IF EXISTS " ++ fresh_database ++
        ";CREATE DATABASE " ++ migrated_database ++ ";CREATE DATABASE " ++ fresh_database);
    try load(migrated_database, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| try load(migrated_database, schema.mysqlMigration(step.from), false);
    try load(fresh_database, schema.ddl(.mysql), false);
    try load(fresh_database, store_testing.expected_mysql_rows, true);
    try expectSameResults(comptime &shapeQueries(migrated_database), comptime &shapeQueries(fresh_database));
    try expectSameResults(comptime rowQueries(migrated_database), comptime rowQueries(fresh_database));
    // What the engine's open compares, on a fresh and a migrated Store.
    try expectCatalog(fresh_database);
    try expectCatalog(migrated_database);
    done.migrations += 1;
    writeRecord();
}

test "schema 55 migrates recovery index and wire 8 together to the current schema and wire" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer setup("USE " ++ database) catch {};
    try setup("DROP DATABASE IF EXISTS " ++ migrated_database ++ ";CREATE DATABASE " ++ migrated_database);
    try load(migrated_database, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| {
        if (step.from < 55) try load(migrated_database, schema.mysqlMigration(step.from), false);
    }
    try load(migrated_database, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','8'),('format','55')", false);
    inline for (schema.migrations) |step| {
        if (step.from >= 55) try load(migrated_database, schema.mysqlMigration(step.from), false);
    }
    var result: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer result.deinit();
    try writeResult("SELECT meta_value FROM store_meta WHERE meta_key='wire_version'", &result.writer);
    try std.testing.expectEqualStrings("\n 1:" ++ protocol.wire_version, result.written());
    try expectCatalog(migrated_database);
    done.migrations += 1;
    writeRecord();
}

/// A live Store conformance body completed successfully.
pub fn conformancePassed() void {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse @panic("conformance ran without MySQL dialect connection");
    done.conformance += 1;
    writeRecord();
}
