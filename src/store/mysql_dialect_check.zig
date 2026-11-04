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
//! probes MySQL refused as expected. CI fails a shard whose record is
//! missing or counts no PREPARE (`tests/integration/live_engines.py`), so
//! any path that keeps the check from running turns red.
//!
//! PREPARE resolves names, types and grammar; it binds no value and runs
//! nothing, so literal typing, guards, row counts, transactions and query
//! plans are not checked here.
const std = @import("std");
const rsql = @import("rsql.zig");
const schema = @import("schema.zig");
const sqlite = @import("sqlite.zig");
const store_testing = @import("testing.zig");
const mysql_driver = @import("wire/mysql_driver.zig");
const mysql = mysql_driver.mysql;

const database = "rui_dialect_check";
const oracle_database = "rui_dialect_check_oracle";

const State = enum { unopened, absent, open, broken };

/// Guards everything below: some Store tests call the Store from threads.
var mutex: std.Io.Mutex = .init;
var state: State = .unopened;
var driver: mysql_driver.Driver = undefined;
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

    pub fn format(counts: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("ddl={d} ddl_refused={d} prepares={d} prepare_refused={d} probes={d}\n", .{
            counts.ddl, counts.ddl_refused, counts.prepares, counts.prepare_refused, counts.probes,
        });
    }
} = .{};

const Config = struct { socket: []const u8, password: []const u8, record: ?[]const u8 };

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
fn connection() ?*mysql_driver.Driver {
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
    driver.open(std.testing.io, .{ .unix_socket = config.socket }, .{ .user = "root", .password = config.password, .database = "mysql" }, &refusal.writer) catch |err| {
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
    while (!driver.client.isReady()) switch (try driver.next()) {
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
