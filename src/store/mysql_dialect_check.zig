const std = @import("std");
const wire_version = @import("../wire_version.zig").wire_version;
const rsql = @import("rsql.zig");
const schema = @import("schema.zig");
const validStoreId = @import("../store_id.zig").valid;
const sqlite = @import("sqlite.zig");
const store_testing = @import("testing.zig");
const mysql_connection = @import("wire/mysql_connection.zig");
const mysql = mysql_connection.mysql;

/// Whether this unit root compiles the shadow PREPAREs. `build.zig` turns it off only
/// in a PR-tier build, which starts no MySQL server.
pub const compiled = @import("mysql_dialect_check_options").compiled;

const database_sql = "{[database]s}";
const oracle_database_sql = "{[oracle]s}";

// The launcher namespaces every process, including native shadow PREPARE checks.
// SQL generators keep named placeholders until their owning call formats them.
const DatabaseNames = struct {
    database: []const u8 = "rui_dialect_check",
    oracle: []const u8 = "rui_dialect_check_oracle",
    migrated: []const u8 = "rui_migration_migrated",
    fresh: []const u8 = "rui_migration_fresh",
    offer: []const u8 = "rui_offer_migration",
    effort: []const u8 = "rui_effort_migration",
    projection: []const u8 = "rui_obligation_projection_parity",
};

var names: DatabaseNames = .{};
var name_buffers: [@typeInfo(DatabaseNames).@"struct".field_names.len][64]u8 = undefined;

fn qualifiedDatabase(buffer: []u8, base: []const u8, namespace: ?[]const u8) ![]const u8 {
    const suffix = namespace orelse return base;
    // Leave room for every base and the migration fixture's derived _oracle.
    if (suffix.len == 0 or suffix.len > 31) return error.InvalidMysqlTestNamespace;
    for (suffix) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidMysqlTestNamespace;
    return std.fmt.bufPrint(buffer, "{s}_{s}", .{ base, suffix });
}

fn configureNames(namespace: ?[]const u8) !void {
    const defaults: DatabaseNames = .{};
    inline for (@typeInfo(DatabaseNames).@"struct".field_names, 0..) |field, i| {
        @field(names, field) = try qualifiedDatabase(&name_buffers[i], @field(defaults, field), namespace);
    }
}

// configured() validates the namespace before deriving either schema or user names.
// A hash fits the account's stricter 32-character limit with the existing prefix.
fn conformanceUser(buffer: []u8, namespace: ?[]const u8) ![]const u8 {
    const suffix = namespace orelse return "rui_conformance";
    return std.fmt.bufPrint(buffer, "rui_conformance_{x:0>16}", .{std.hash.Wyhash.hash(0, suffix)});
}

test "MySQL conformance account namespace preserves defaults and separates concurrent processes" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("rui_conformance", try conformanceUser(&buffer, null));
    const namespaces = [_][]const u8{ "n123", "s123_0", "s123_1", "s124_0", "u123" };
    var users: [namespaces.len][32]u8 = undefined;
    for (namespaces, 0..) |namespace, i| {
        const user = try conformanceUser(&users[i], namespace);
        try std.testing.expectEqual(@as(usize, 32), user.len);
        try std.testing.expect(std.mem.startsWith(u8, user, "rui_conformance_"));
        try std.testing.expectEqualStrings(user, try conformanceUser(&buffer, namespace));
        for (users[0..i]) |previous| try std.testing.expect(!std.mem.eql(u8, user, &previous));
    }
}

fn SqlNames(comptime text: []const u8) type {
    comptime {
        @setEvalBranchQuota(10000 + text.len * 100);
        var fields: []const []const u8 = &.{};
        for (@typeInfo(DatabaseNames).@"struct".field_names) |field| {
            if (std.mem.indexOf(u8, text, "{[" ++ field ++ "]s}") != null) fields = fields ++ .{field};
        }
        const types: [fields.len]type = @splat([]const u8);
        return @Struct(.auto, null, fields, &types, &@splat(.{}));
    }
}

fn sqlNames(comptime text: []const u8, values: DatabaseNames) SqlNames(text) {
    var args: SqlNames(text) = undefined;
    inline for (@typeInfo(SqlNames(text)).@"struct".field_names) |field| {
        @field(args, field) = @field(values, field);
    }
    return args;
}

fn setupNamed(comptime text: []const u8) !void {
    const sql = try std.fmt.allocPrint(std.testing.allocator, text, sqlNames(text, names));
    defer std.testing.allocator.free(sql);
    try setup(sql);
}

fn restoreNamed(comptime text: []const u8) void {
    const sql = std.fmt.allocPrint(std.testing.allocator, text, sqlNames(text, names)) catch |err|
        return finishRestoration(err, text, RestoreLog{});
    defer std.testing.allocator.free(sql);
    restore(sql);
}

fn ddlNamed(name: []const u8, comptime text: []const u8) !void {
    const sql = try std.fmt.allocPrint(std.testing.allocator, text, sqlNames(text, names));
    defer std.testing.allocator.free(sql);
    try ddl(name, sql);
}

fn writeResultNamed(comptime text: []const u8, out: *std.Io.Writer) !void {
    const sql = try std.fmt.allocPrint(std.testing.allocator, text, sqlNames(text, names));
    defer std.testing.allocator.free(sql);
    try writeResult(sql, out);
}

test "MySQL test schema namespace preserves defaults and separates concurrent processes" {
    const defaults: DatabaseNames = .{};
    inline for (@typeInfo(DatabaseNames).@"struct".field_names) |field| {
        const base = @field(defaults, field);
        var native: [64]u8 = undefined;
        var shard0: [64]u8 = undefined;
        var shard1: [64]u8 = undefined;
        try std.testing.expectEqualStrings(base, try qualifiedDatabase(&native, base, null));
        const n = try qualifiedDatabase(&native, base, "n123");
        const s0 = try qualifiedDatabase(&shard0, base, "s123_0");
        const s1 = try qualifiedDatabase(&shard1, base, "s123_1");
        try std.testing.expect(!std.mem.eql(u8, n, s0));
        try std.testing.expect(!std.mem.eql(u8, n, s1));
        try std.testing.expect(!std.mem.eql(u8, s0, s1));
        try std.testing.expectEqualStrings(base, s0[0..base.len]);
        try std.testing.expectEqualStrings("_s123_0", s0[base.len..]);
        const maximum = try qualifiedDatabase(&shard0, base, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
        try std.testing.expect(maximum.len <= 64);
        if (comptime std.mem.eql(u8, field, "migrated")) try std.testing.expect(maximum.len + "_oracle".len <= 64);
    }
    const sql = try std.fmt.allocPrint(std.testing.allocator, "USE " ++ database_sql ++ ";SELECT * FROM " ++ oracle_database_sql ++ ".touched_oracle", sqlNames("USE " ++ database_sql ++ ";SELECT * FROM " ++ oracle_database_sql ++ ".touched_oracle", .{ .database = "rui_dialect_check_s123_0", .oracle = "rui_dialect_check_oracle_s123_0" }));
    defer std.testing.allocator.free(sql);
    try std.testing.expectEqualStrings("USE rui_dialect_check_s123_0;SELECT * FROM rui_dialect_check_oracle_s123_0.touched_oracle", sql);
    var buffer: [64]u8 = undefined;
    for ([_][]const u8{ "", "bad-name", "bad.name", "bad'name", "a/b", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }) |invalid| {
        try std.testing.expectError(error.InvalidMysqlTestNamespace, qualifiedDatabase(&buffer, "rui_fixture", invalid));
    }
}

const State = enum { unopened, absent, open, broken };

pub const touch_oracle_definition = "(session_ref VARCHAR(6)) ENGINE=MEMORY";

var mutex: std.Io.Mutex = .init;
var state: State = .unopened;
var driver: mysql_connection.Connection = undefined;
var ddl_refusals: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
var socket_buffer: [std.Io.net.UnixAddress.max_len]u8 = undefined;
var password_buffer: [mysql.max_password_bytes]u8 = undefined;
var conformance_user_buffer: [32]u8 = undefined;
var record_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
var record_path: ?[]const u8 = null;
var done: struct {
    ddl: u32 = 0,
    ddl_refused: u32 = 0,
    prepares: u32 = 0,
    prepare_refused: u32 = 0,
    probes: u32 = 0,
    migrations: u32 = 0,
    conformance: u32 = 0,

    pub fn format(counts: @This(), w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("ddl={d} ddl_refused={d} prepares={d} prepare_refused={d} probes={d} migrations={d} conformance={d}\n", .{
            counts.ddl, counts.ddl_refused, counts.prepares, counts.prepare_refused, counts.probes, counts.migrations, counts.conformance,
        });
    }
} = .{};

pub const Config = struct { socket: []const u8, password: []const u8, record: ?[]const u8, conformance_user: []const u8 };

fn configured() !?Config {
    var environ = try std.testing.environ.createMap(std.heap.page_allocator);
    defer environ.deinit();
    const socket = environ.get("RUI_TEST_MYSQL_SOCKET");
    const password = environ.get("RUI_TEST_MYSQL_ROOT_PASSWORD");
    const server = socket != null or password != null or (try store_testing.requiredEngines()).contains(.mysql);
    switch (decide(compiled, server)) {
        .skip => return null,
        .refuse => return error.MysqlDialectCheckCompiledOut,
        .prepare => {},
    }
    if (socket == null or password == null) return error.MysqlRequired;
    if (socket.?.len > socket_buffer.len or password.?.len > password_buffer.len) return error.MysqlConfigTooLong;
    @memcpy(socket_buffer[0..socket.?.len], socket.?);
    @memcpy(password_buffer[0..password.?.len], password.?);
    const namespace = environ.get("RUI_UNIT_MYSQL_NAMESPACE");
    try configureNames(namespace);
    const conformance_user = try conformanceUser(&conformance_user_buffer, namespace);
    const record = environ.get("RUI_TEST_MYSQL_RECORD");
    if (record) |path| {
        if (path.len > record_buffer.len) return error.MysqlConfigTooLong;
        @memcpy(record_buffer[0..path.len], path);
    }
    return .{
        .socket = socket_buffer[0..socket.?.len],
        .password = password_buffer[0..password.?.len],
        .record = if (record) |path| record_buffer[0..path.len] else null,
        .conformance_user = conformance_user,
    };
}

pub fn rootConfig() !?Config {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    return configured();
}

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

fn bootstrap() !void {
    try setupNamed("DROP DATABASE IF EXISTS " ++ database_sql ++ ";DROP DATABASE IF EXISTS " ++ oracle_database_sql ++
        ";CREATE DATABASE " ++ database_sql ++ ";CREATE DATABASE " ++ oracle_database_sql ++ ";USE " ++ database_sql);
    for (schema.mysql_session) |text| try setup(text);
    const objects = comptime schema.objects(.mysql);
    for (objects) |object| try ddl(object.name, object.sql);
    try ddlNamed("touch oracle", "CREATE TABLE " ++ oracle_database_sql ++ ".touched_oracle" ++ touch_oracle_definition);
    const triggers = comptime sqlite.touchOracleTriggers(.mysql, oracle_database_sql ++ ".touched_oracle");
    inline for (triggers) |text| try ddlNamed("touch oracle", text);
}

fn setup(text: []const u8) !void {
    if (try run(text)) |refused| {
        std.log.err("MySQL dialect check: MySQL refused {s}: {f}", .{ text, refused });
        return error.MysqlRefusedSetup;
    }
}

fn restore(text: []const u8) void {
    finishRestoration(setup(text), text, RestoreLog{});
}

const RestoreLog = struct {
    fn failed(_: RestoreLog, text: []const u8, err: anyerror) void {
        std.log.err("MySQL dialect check: restoration failed: {s}\n  {s}", .{ @errorName(err), text });
    }
};

fn finishRestoration(result: anyerror!void, text: []const u8, report: anytype) void {
    result catch |err| {
        state = .broken;
        if (err != error.MysqlRefusedSetup) report.failed(text, err);
    };
}

const TestRestoreReport = struct {
    failures: usize = 0,
    text: []const u8 = "",
    cause: ?anyerror = null,

    fn failed(self: *TestRestoreReport, text: []const u8, err: anyerror) void {
        self.failures += 1;
        self.text = text;
        self.cause = err;
    }

    fn body(self: *TestRestoreReport, result: anyerror!void, restoration: anyerror!void) !void {
        defer finishRestoration(restoration, "USE restoration_fixture", self);
        return result;
    }
};

test "MySQL restoration reports every transport failure and keeps a body failure primary" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const saved = state;
    defer state = saved;
    for ([_]anyerror{ error.ConnectionLost, error.DeadlineExceeded }) |transport_error| {
        for ([_]bool{ false, true }) |body_failed| {
            state = .open;
            var report: TestRestoreReport = .{};
            const outcome = report.body(if (body_failed) error.InjectedMigrationBodyFailure else {}, transport_error);
            if (body_failed) try std.testing.expectError(error.InjectedMigrationBodyFailure, outcome) else try outcome;
            try std.testing.expectEqual(@as(usize, 1), report.failures);
            try std.testing.expectEqual(transport_error, report.cause.?);
            try std.testing.expectEqualStrings("USE restoration_fixture", report.text);
            try std.testing.expectEqual(State.broken, state);
        }
    }
    var report: TestRestoreReport = .{};
    state = .open;
    try report.body({}, {});
    try std.testing.expectEqual(@as(usize, 0), report.failures);
    try std.testing.expectEqual(State.open, state);
    finishRestoration(error.MysqlRefusedSetup, "SET FOREIGN_KEY_CHECKS=1", &report);
    try std.testing.expectEqual(@as(usize, 0), report.failures);
    try std.testing.expectEqual(State.broken, state);
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

const Decision = enum { prepare, skip, refuse };

/// A build without the check must not stand in for one against a live server.
fn decide(compiled_in: bool, server: bool) Decision {
    if (!server) return .skip;
    return if (compiled_in) .prepare else .refuse;
}

pub fn shadowPrepare(comptime text: []const u8) void {
    if (comptime !compiled) return;
    once(text, null);
}

pub fn shadowPrepareStatement(comptime S: type) void {
    if (comptime !compiled) return;
    once(comptime S.mysql.prepared(), null);
}

pub fn shadowPrepareFixture(comptime text: []const u8) void {
    if (comptime !compiled) return;
    switch (comptime rsql.mysqlRendering(text)) {
        .refused => |message| once(text, message),
        .rendered => |template| inline for (comptime statements(template.prepared())) |statement| once(statement, null),
    }
}

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

fn Once(comptime text: []const u8) type {
    return struct {
        const key = text;
        var done: std.atomic.Value(bool) = .init(false);
    };
}

fn prepareQuery(comptime text: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10 * text.len + 1000);
        // Fill a buffer sized from the text: appending a byte at a time with
        // `++` copies the whole prefix on every byte.
        var quoted: [text.len + std.mem.countScalar(u8, text, '\'')]u8 = undefined;
        var at: usize = 0;
        for (text) |byte| {
            quoted[at] = byte;
            at += 1;
            if (byte == '\'') {
                quoted[at] = byte;
                at += 1;
            }
        }
        const final = quoted;
        return "PREPARE rui_dialect_check FROM '" ++ &final ++ "';DEALLOCATE PREPARE rui_dialect_check";
    }
}

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

test "SH-70 the dialect check prepares only when compiled in, skips without a server, and refuses a server it cannot check" {
    const cases = [_]struct { compiled_in: bool, server: bool, want: Decision }{
        .{ .compiled_in = true, .server = true, .want = .prepare },
        .{ .compiled_in = true, .server = false, .want = .skip },
        .{ .compiled_in = false, .server = false, .want = .skip },
        .{ .compiled_in = false, .server = true, .want = .refuse },
    };
    for (cases) |case| try std.testing.expectEqual(case.want, decide(case.compiled_in, case.server));
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

const migrated_database_sql = "{[migrated]s}";
const fresh_database_sql = "{[fresh]s}";

fn load(comptime name: []const u8, text: []const u8, unchecked: bool) !void {
    try setupNamed("USE " ++ name);
    if (unchecked) try setup("SET FOREIGN_KEY_CHECKS=0");
    defer if (unchecked) restore("SET FOREIGN_KEY_CHECKS=1");
    if (try run(text)) |refused| {
        std.log.err("MySQL migration check: {s} refused: {f}", .{ name, refused });
        return error.MysqlRefusedMigration;
    }
}

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

fn rowQueries(comptime name: []const u8) []const []const u8 {
    var queries: []const []const u8 = &.{};
    for (schema.tables) |table| if (table.engines.on(.mysql)) {
        var order: []const u8 = "";
        for (table.primary_key, 0..) |column, position| order = order ++ (if (position == 0) "" else ",") ++ column;
        queries = queries ++ .{"SELECT * FROM " ++ name ++ "." ++ table.name ++ " ORDER BY " ++ order};
    };
    return queries;
}

fn expectCatalog(comptime name: []const u8) !void {
    var lines: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer lines.deinit();
    try writeResultNamed(comptime schema.catalogSql("'" ++ name ++ "'"), &lines.writer);
    var sum: u64 = 0;
    var rows = std.mem.splitScalar(u8, lines.written(), '\n');
    while (rows.next()) |row| {
        if (row.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, row, ':') orelse return error.MysqlCatalogRow;
        sum +%= schema.catalogLineDigest(row[colon + 1 ..]);
    }
    if (sum == schema.catalogDigest()) return;
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

fn expectSameResults(comptime migrated: []const []const u8, comptime fresh: []const []const u8) !void {
    inline for (migrated, fresh) |left, right| {
        var left_result: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer left_result.deinit();
        var right_result: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer right_result.deinit();
        try writeResultNamed(left, &left_result.writer);
        try writeResultNamed(right, &right_result.writer);
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
    defer restoreNamed("USE " ++ database_sql);
    try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";DROP DATABASE IF EXISTS " ++ fresh_database_sql ++
        ";CREATE DATABASE " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ fresh_database_sql);
    try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database_sql, store_testing.baseline_rows, true);
    const selector = "/mysql-migration-store";
    try load(migrated_database_sql, std.fmt.comptimePrint(
        "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','{d}'),('wire_version','7'),('store_selector','{s}')",
        .{ schema.migration_baseline, selector },
    ), false);
    try load(migrated_database_sql, schema.mysqlMigrationFrom(schema.migration_baseline).?, false);
    try load(fresh_database_sql, schema.ddl(.mysql), false);
    try load(fresh_database_sql, store_testing.expected_mysql_rows, true);
    try load(fresh_database_sql, std.fmt.comptimePrint(
        "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','{d}'),('store_selector','{s}')",
        .{ schema.schema_version, selector },
    ), false);
    try expectSameResults(comptime &shapeQueries(migrated_database_sql), comptime &shapeQueries(fresh_database_sql));
    try expectSameResults(comptime rowQueries(migrated_database_sql), comptime rowQueries(fresh_database_sql));
    try expectCatalog(fresh_database_sql);
    try expectCatalog(migrated_database_sql);

    const config = (try configured()).?;
    const probe = try std.testing.allocator.create(mysql_connection.Connection);
    defer std.testing.allocator.destroy(probe);
    var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refusal.deinit();
    try probe.open(.{ .address = .{ .unix_socket = config.socket }, .user = "root", .password = config.password, .database = names.migrated }, &refusal.writer);
    defer probe.close();
    var found: u32 = 0;
    const opened = try @import("engine/mysql_open.zig").open(probe, io, .{ .database = names.migrated, .found_schema_version = &found }, selector);
    try std.testing.expectEqual(schema.schema_version, found);
    try std.testing.expect(opened.epoch > 0);
    try std.testing.expect(validStoreId(&opened.store_id));
    done.migrations += 1;
    writeRecord();
}

test "schema 82 MySQL migration backfills input sources and preserves admissions" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
    try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database_sql, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| {
        if (step.from < 81) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
    }
    try load(migrated_database_sql, "UPDATE message_admission SET sender_session_ref='brhkcj',sender_position=1 WHERE admission_id=1;" ++
        "UPDATE message_admission SET source_action_id=(SELECT min(action_id) FROM action_operation) WHERE admission_id=2;" ++
        "INSERT INTO message_admission(admission_id,session_ref,command_key,content_id,admitted_at) VALUES(3,'rhvzwc','fixture-stop',1,1)", false);
    const saved_rows = "SELECT admission_id,session_ref,command_key,content_id,admission_position,turn_id,admitted_at,sender_session_ref,sender_position,source_action_id FROM message_admission ORDER BY admission_id";
    var before: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer before.deinit();
    try writeResult(saved_rows, &before.writer);
    try std.testing.expect(before.written().len > 0);
    try load(migrated_database_sql, schema.mysqlMigration(81), false);
    var after: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer after.deinit();
    try writeResult(saved_rows, &after.writer);
    try std.testing.expectEqualStrings(before.written(), after.written());
    var kinds: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer kinds.deinit();
    try writeResult("SELECT count(*) FROM message_admission WHERE (admission_id=1 AND source_kind=2 AND message_admission_person_lead IS NULL) OR (admission_id=2 AND source_kind=3 AND message_admission_person_lead IS NULL) OR (admission_id=3 AND source_kind=1 AND message_admission_person_lead=session_ref)", &kinds.writer);
    try std.testing.expectEqualStrings("\n 1:3", kinds.written());
    const refusal = (try run("UPDATE message_admission SET source_kind=1 WHERE admission_id=1")) orelse return error.MissingSourceKindRefusal;
    try std.testing.expectEqual(@as(u16, 3819), refusal.code);
    try expectCatalog(migrated_database_sql);
    done.migrations += 1;
    writeRecord();
}

test "model call timing MySQL format 68 migration preserves format 67 resolutions with null final attempt timings" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
    try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database_sql, store_testing.baseline_rows, true);
    inline for (schema.migrations[0 .. 67 - schema.migration_baseline]) |step| {
        try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
    }
    const facts = "SELECT operation_id,attempt_ordinal,resolution_code,resolved_at FROM model_operation ORDER BY operation_id";
    var before: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer before.deinit();
    try writeResult(facts, &before.writer);
    try std.testing.expect(before.written().len > 0);
    try load(migrated_database_sql, schema.mysqlMigration(67), false);
    var after: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer after.deinit();
    try writeResult(facts, &after.writer);
    try std.testing.expectEqualStrings(before.written(), after.written());
    var timings: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer timings.deinit();
    try writeResult("SELECT count(*) FROM model_operation WHERE latency_ms IS NOT NULL OR first_event_ms IS NOT NULL", &timings.writer);
    try std.testing.expectEqualStrings("\n 1:0", timings.written());
    try load(migrated_database_sql, schema.mysqlMigrationFrom(68).?, false);
    try expectCatalog(migrated_database_sql);
    done.migrations += 1;
    writeRecord();
}

test "schema 55 migrates recovery index and wire 8 together to the current schema without a wire label" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
    try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database_sql, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| {
        if (step.from < 55) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
    }
    try load(migrated_database_sql, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','8'),('format','55')", false);
    try load(migrated_database_sql, schema.mysqlMigrationFrom(55).?, false);
    var result: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer result.deinit();
    try writeResult("SELECT meta_value FROM store_meta WHERE meta_key='wire_version'", &result.writer);
    try std.testing.expectEqualStrings("", result.written());
    try expectCatalog(migrated_database_sql);
    done.migrations += 1;
    writeRecord();
}

pub fn conformancePassed() void {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse @panic("conformance ran without MySQL dialect connection");
    done.conformance += 1;
    writeRecord();
}

test "skills schema 56 wire 9 MySQL migration preserves ordinary rows and reaches the current shape" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
    try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database_sql, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| {
        if (step.from < 56) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
    }
    try load(migrated_database_sql, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','9'),('format','56')", false);
    var old_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer old_wire.deinit();
    try writeResult("SELECT meta_value FROM store_meta WHERE meta_key='wire_version'", &old_wire.writer);
    try std.testing.expectEqualStrings("\n 1:9", old_wire.written());
    var count: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer count.deinit();
    try writeResult("SELECT count(*) FROM conversation_entry", &count.writer);
    try std.testing.expectEqualStrings("\n 1:3", count.written());
    const ordinary_rows = "SELECT e.session_ref,e.entry_ordinal,e.session_position,e.entry_kind,e.turn_id,e.source_admission_id,e.source_revision,e.source_operation_id,e.source_item_ordinal,e.content_id,e.recorded_at,HEX(c.digest),c.byte_length,c.private,k.chunk_index,HEX(k.bytes) " ++
        "FROM conversation_entry e JOIN content c ON c.content_id=e.content_id LEFT JOIN content_chunk k ON k.content_id=c.content_id ORDER BY e.session_ref,e.entry_ordinal,k.chunk_index";
    var before: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer before.deinit();
    try writeResult(ordinary_rows, &before.writer);
    try std.testing.expect(before.written().len > 100);
    try load(migrated_database_sql, schema.mysqlMigrationFrom(56).?, false);
    var result: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer result.deinit();
    try writeResult("SELECT meta_value FROM store_meta WHERE meta_key='wire_version'", &result.writer);
    try std.testing.expectEqualStrings("", result.written());
    var after: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer after.deinit();
    try writeResult(ordinary_rows, &after.writer);
    try std.testing.expectEqualStrings(before.written(), after.written());
    var provenance: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer provenance.deinit();
    try writeResult("SELECT count(*) FROM conversation_entry WHERE source_catalog_position IS NULL AND turn_id IS NOT NULL", &provenance.writer);
    try std.testing.expectEqualStrings("\n 1:3", provenance.written());
    try expectCatalog(migrated_database_sql);
    done.migrations += 1;
    writeRecord();
}

test "skills schema 58 wire 10 MySQL migration preserves archive refusal and ordinary rows" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
    try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database_sql, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| {
        if (step.from < 58) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
    }
    try load(migrated_database_sql, "INSERT INTO store_meta(meta_key,meta_value) VALUES('wire_version','10'),('format','58')", false);
    try load(migrated_database_sql, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES" ++
        "('skills-58-archive',6,'rhvzwc',X'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',1,'',0,0,1000)," ++
        "('skills-58-refusal',2,'absent',X'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',0,'unknown_session',0,0,1001);" ++
        "INSERT INTO session_stop(command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused) VALUES('skills-58-archive','rhvzwc',NULL,2,0,1793781800,0);" ++
        "INSERT INTO session_archive(session_ref,command_key) VALUES('rhvzwc','skills-58-archive');" ++
        "INSERT INTO session_archive_command(command_key,archived) VALUES('skills-58-archive',1);" ++
        "INSERT INTO sent_rejection(command_key,sender_session_ref,sender_position,rejected_at) VALUES('skills-58-refusal','brhkcj',6,1793781801);" ++
        "UPDATE session SET next_position=3 WHERE session_ref='rhvzwc';" ++
        "UPDATE session SET next_position=7 WHERE session_ref='brhkcj'", false);
    const saved_facts = "SELECT c.command_key,c.kind,c.target,HEX(c.input_digest),c.accepted,c.code,c.command_seq,a.archived,s.session_ref,s.selected_turn_id,s.position,s.admission_cutoff,s.stopped_at,s.parent_caused,intent.session_ref,r.sender_session_ref,r.sender_position,r.rejected_at " ++
        "FROM core_command c LEFT JOIN session_archive_command a ON a.command_key=c.command_key LEFT JOIN session_stop s ON s.command_key=c.command_key LEFT JOIN session_archive intent ON intent.command_key=c.command_key LEFT JOIN sent_rejection r ON r.command_key=c.command_key " ++
        "WHERE c.command_key IN ('skills-58-archive','skills-58-refusal') ORDER BY c.command_key";
    var before_facts: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer before_facts.deinit();
    try writeResult(saved_facts, &before_facts.writer);
    try std.testing.expect(before_facts.written().len > 200);
    var old_wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer old_wire.deinit();
    try writeResult("SELECT meta_value FROM store_meta WHERE meta_key='wire_version'", &old_wire.writer);
    try std.testing.expectEqualStrings("\n 2:10", old_wire.written());
    var count: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer count.deinit();
    try writeResult("SELECT count(*) FROM conversation_entry", &count.writer);
    try std.testing.expectEqualStrings("\n 1:3", count.written());
    const ordinary_rows = "SELECT e.session_ref,e.entry_ordinal,e.session_position,e.entry_kind,e.turn_id,e.source_admission_id,e.source_revision,e.source_operation_id,e.source_item_ordinal,e.content_id,e.recorded_at,HEX(c.digest),c.byte_length,c.private,k.chunk_index,HEX(k.bytes) " ++
        "FROM conversation_entry e JOIN content c ON c.content_id=e.content_id LEFT JOIN content_chunk k ON k.content_id=c.content_id ORDER BY e.session_ref,e.entry_ordinal,k.chunk_index";
    var before: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer before.deinit();
    try writeResult(ordinary_rows, &before.writer);
    try std.testing.expect(before.written().len > 100);
    try load(migrated_database_sql, schema.mysqlMigrationFrom(58).?, false);
    var result: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer result.deinit();
    try writeResult("SELECT meta_value FROM store_meta WHERE meta_key='wire_version'", &result.writer);
    try std.testing.expectEqualStrings("", result.written());
    var after: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer after.deinit();
    try writeResult(ordinary_rows, &after.writer);
    try std.testing.expectEqualStrings(before.written(), after.written());
    var after_facts: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer after_facts.deinit();
    try writeResult(saved_facts, &after_facts.writer);
    try std.testing.expectEqualStrings(before_facts.written(), after_facts.written());
    var provenance: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer provenance.deinit();
    try writeResult("SELECT count(*) FROM conversation_entry WHERE source_catalog_position IS NULL AND turn_id IS NOT NULL", &provenance.writer);
    try std.testing.expectEqualStrings("\n 1:3", provenance.written());
    try expectCatalog(migrated_database_sql);
    done.migrations += 1;
    writeRecord();
}

test "fixture and typed statement PREPARE text retains MySQL index hints" {
    const text = "SELECT revision FROM session_revision r @index(session_revision_instructions) WHERE r.session_ref=?1 AND r.instructions_content_id=?2";
    const S = rsql.Read(.{
        .sql = text,
        .Args = struct { session: []const u8, content_id: u64 },
        .Row = struct { revision: u64 },
        .cardinality = .each,
    });
    shadowPrepare(comptime S.mysql.prepared());
    const fixture = comptime rsql.mysqlRendering(text).rendered.prepared();
    const pieces = comptime statements(fixture);
    try std.testing.expectEqual(@as(usize, 1), pieces.len);
    try std.testing.expectEqualStrings(comptime S.mysql.prepared(), pieces[0]);
    try std.testing.expectEqualStrings(
        "PREPARE rui_dialect_check FROM 'SELECT revision FROM session_revision r FORCE INDEX (session_revision_instructions) WHERE r.session_ref=? AND r.instructions_content_id=?';DEALLOCATE PREPARE rui_dialect_check",
        comptime prepareQuery(pieces[0]),
    );
}

test "metadata seed MySQL missing masks retain canonical selector and id" {
    const id = "0123456789abcdef0123456789abcdef".*;
    const selector = "/canonical/'\\é";
    const expected = [_][]const u8{
        "INSERT INTO store_meta(meta_key,meta_value) VALUES('store_selector',_utf8mb4 X'2f63616e6f6e6963616c2f275cc3a9' COLLATE utf8mb4_0900_bin);",
        "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','" ++ std.fmt.comptimePrint("{d}", .{schema.schema_version}) ++ "');",
        "INSERT INTO store_meta(meta_key,meta_value) VALUES('store_id','0123456789abcdef0123456789abcdef');",
    };
    const repaired = [_]schema.MetaKey{ .store_selector, .format, .store_id };
    for (0..8) |mask| {
        var seen: schema.MetaPresence = .empty;
        var wanted: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer wanted.deinit();
        for (repaired, expected, 0..) |key, sql, bit| {
            if (mask & (@as(usize, 1) << @intCast(bit)) != 0) {
                seen.insert(key);
            } else try wanted.writer.writeAll(sql);
        }
        var actual: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer actual.deinit();
        try schema.writeMissingMeta(&actual.writer, seen, &id, selector);
        try std.testing.expectEqualStrings(wanted.written(), actual.written());
    }
    const first = schema.drawStoreId(std.testing.io);
    const second = schema.drawStoreId(std.testing.io);
    try std.testing.expect(validStoreId(&first));
    try std.testing.expect(validStoreId(&second));
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "frozen context window schema 69 MySQL migration pins legacy policy and preserves live and settled rows" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
    try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database_sql, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| {
        if (step.from < 68) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
    }
    try load(migrated_database_sql, @embedFile("migration_window_rows.sql"), false);
    try load(migrated_database_sql, "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','68'),('wire_version','" ++ wire_version ++ "')", false);
    try load(migrated_database_sql, schema.mysqlMigrationFrom(68).?, false);
    try expectSameResults(&.{
        "SELECT operation_id,context_window FROM model_operation ORDER BY operation_id",
        "SELECT operation_id,tool_set_id FROM model_operation ORDER BY operation_id",
        "SELECT reasoning_effort,effort_source_revision,previous_reasoning_effort,effort_update,previous_effort_override FROM model_operation WHERE operation_id=4",
        "SELECT operation_id,latency_ms,first_event_ms FROM model_operation ORDER BY operation_id",
        "SELECT operation_id FROM model_operation WHERE operation_id=3 AND resolution_code IS NULL AND retry_due_at_ms=0 AND attempt_at=1",
        "SELECT operation_id FROM model_operation WHERE operation_id=4 AND resolution_code='context_overflow' AND history_floor=3 AND history_level=2 AND history_dropped=4 AND output_reservation=8",
        "SELECT IS_NULLABLE,COLUMN_DEFAULT FROM information_schema.columns WHERE table_schema='" ++ migrated_database_sql ++ "' AND table_name='model_operation' AND column_name='context_window'",
    }, &.{
        "SELECT 1,1050000 UNION ALL SELECT 2,128000 UNION ALL SELECT 3,1050000 UNION ALL SELECT 4,128000",
        "SELECT 1,4 UNION ALL SELECT 2,2 UNION ALL SELECT 3,2 UNION ALL SELECT 4,2",
        "SELECT 'high',1,'low',1,'medium'",
        "SELECT 1,13,4 UNION ALL SELECT 2,NULL,NULL UNION ALL SELECT 3,NULL,NULL UNION ALL SELECT 4,29,7",
        "SELECT 3",
        "SELECT 4",
        "SELECT 'NO',NULL",
    });
    try expectCatalog(migrated_database_sql);
    done.migrations += 1;
    writeRecord();
}

test "schema 74 MySQL migration deletes the saved wire label, and the Store opens without one" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
    try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database_sql, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| {
        if (step.from < 73) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
    }
    const selector = "/mysql-wire-retirement";
    try load(migrated_database_sql, "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','73'),('wire_version','16'),('store_selector','" ++ selector ++ "')", false);
    try load(migrated_database_sql, schema.mysqlMigration(73), false);
    try expectSameResults(&.{
        "SELECT count(*) FROM store_meta WHERE meta_key='wire_version'",
        "SELECT meta_value FROM store_meta WHERE meta_key='format'",
        "SELECT count(*) FROM session WHERE session_ref='d8mv7p'",
    }, &.{
        "SELECT 0",
        "SELECT '73'",
        "SELECT 1",
    });
    try load(migrated_database_sql, schema.mysqlMigrationFrom(73).?, false);
    try expectCatalog(migrated_database_sql);
    const config = (try configured()).?;
    const probe = try std.testing.allocator.create(mysql_connection.Connection);
    defer std.testing.allocator.destroy(probe);
    var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refusal.deinit();
    try probe.open(.{ .address = .{ .unix_socket = config.socket }, .user = "root", .password = config.password, .database = names.migrated }, &refusal.writer);
    defer probe.close();
    var found: u32 = 0;
    _ = try @import("engine/mysql_open.zig").open(probe, io, .{ .database = names.migrated, .found_schema_version = &found }, selector);
    try std.testing.expectEqual(schema.schema_version, found);
    try expectSameResults(&.{"SELECT count(*) FROM " ++ migrated_database_sql ++ ".store_meta WHERE meta_key='wire_version'"}, &.{"SELECT 0"});
    done.migrations += 1;
    writeRecord();
}

test "schema 72 MySQL migration updates the saved wire label and preserves ordinary rows" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
    try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database_sql, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| {
        if (step.from < 71) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
    }
    try load(migrated_database_sql, "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','71'),('wire_version','15')", false);
    try load(migrated_database_sql, schema.mysqlMigration(71), false);
    try expectSameResults(&.{
        "SELECT meta_value FROM store_meta WHERE meta_key='wire_version'",
        "SELECT meta_value FROM store_meta WHERE meta_key='format'",
        "SELECT count(*) FROM session WHERE session_ref='d8mv7p'",
    }, &.{
        "SELECT '16'",
        "SELECT '71'",
        "SELECT 1",
    });
    try load(migrated_database_sql, schema.mysqlMigrationFrom(71).?, false);
    try expectCatalog(migrated_database_sql);
    done.migrations += 1;
    writeRecord();
}

test "schema 71 MySQL migration updates the saved wire label and preserves ordinary rows" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
    try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
    try load(migrated_database_sql, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| {
        if (step.from < 70) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
    }
    try load(migrated_database_sql, "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','70'),('wire_version','14')", false);
    try load(migrated_database_sql, schema.mysqlMigration(70), false);
    try expectSameResults(&.{
        "SELECT meta_value FROM store_meta WHERE meta_key='wire_version'",
        "SELECT meta_value FROM store_meta WHERE meta_key='format'",
        "SELECT count(*) FROM session WHERE session_ref='d8mv7p'",
    }, &.{
        "SELECT '15'",
        "SELECT '70'",
        "SELECT 1",
    });
    try load(migrated_database_sql, schema.mysqlMigrationFrom(70).?, false);
    try expectCatalog(migrated_database_sql);
    done.migrations += 1;
    writeRecord();
}

test "schema 70 MySQL migration updates the saved wire label and preserves ordinary rows" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
        defer restoreNamed("USE " ++ database_sql);
        try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
        try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
        try load(migrated_database_sql, store_testing.baseline_rows, true);
        inline for (schema.migrations) |step| {
            if (step.from < 69) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
        }
        try load(migrated_database_sql, "UPDATE session SET parent_ref='d8mv7p' WHERE session_ref='brhkcj'", false);
        try load(migrated_database_sql, "INSERT INTO store_meta(meta_key,meta_value) VALUES('format','69'),('wire_version','13'),('store_selector','/mysql-wire-migration')", false);
        try load(migrated_database_sql, schema.mysqlMigration(69), false);
        try expectSameResults(&.{
            "SELECT meta_value FROM store_meta WHERE meta_key='wire_version'",
            "SELECT meta_value FROM store_meta WHERE meta_key='format'",
            "SELECT count(*) FROM session WHERE session_ref='d8mv7p'",
        }, &.{
            "SELECT '14'",
            "SELECT '69'",
            "SELECT 1",
        });
        try load(migrated_database_sql, schema.mysqlMigrationFrom(69).?, false);
        try expectCatalog(migrated_database_sql);
        try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ "_oracle;CREATE DATABASE " ++ migrated_database_sql ++ "_oracle;CREATE TABLE " ++ migrated_database_sql ++ "_oracle.touched_oracle" ++ touch_oracle_definition);
        inline for (comptime sqlite.touchOracleTriggers(.mysql, migrated_database_sql ++ "_oracle.touched_oracle")) |text| try setupNamed(text);
        done.migrations += 1;
        writeRecord();
    }
    const config = (try rootConfig()).?;
    for (0..2) |_| {
        var storage: @import("Store.zig").Store = undefined;
        try storage.openTarget(io, .{ .mysql = .{
            .address = .{ .unix_socket = config.socket },
            .user = "root",
            .password = config.password,
            .database = names.migrated,
        } }, "/mysql-wire-migration", .{});
        defer storage.close() catch unreachable;
        try @import("tests.zig").expectWireMigrationFacts(&storage, &tmp);
    }
}

test "schema 65 MySQL migration freezes each Operation offer and preserves Session intent" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    const name = "{[offer]s}";
    try setupNamed("DROP DATABASE IF EXISTS " ++ name ++ ";CREATE DATABASE " ++ name);
    defer restoreNamed("DROP DATABASE IF EXISTS " ++ name);
    try load(name, store_testing.baseline_mysql_ddl, false);
    try load(name, store_testing.baseline_rows, true);
    inline for (schema.migrations) |step| {
        if (comptime step.from < 64) try load(name, schema.mysqlMigration(step.from), false);
    }
    try load(name, store_testing.operation_offer_migration_seed, false);
    try load(name, schema.mysqlMigration(64), false);
    var rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer rows.deinit();
    try writeResultNamed("SELECT operation_id,tool_set_id FROM " ++ name ++ ".model_operation ORDER BY operation_id", &rows.writer);
    try std.testing.expectEqualStrings("\n 1:1 1:4\n 1:2 1:2\n 2:99 1:2", rows.written());
    rows.clearRetainingCapacity();
    try writeResultNamed("SELECT revision,tool_set_id,loaded_tool_set_id FROM " ++ name ++ ".session WHERE session_ref='d8mv7p'", &rows.writer);
    try std.testing.expectEqualStrings("\n 1:2 1:4 1:2", rows.written());
    done.migrations += 1;
    writeRecord();
}

test "schema 66 MySQL migration freezes actual effort emission and prior admitted fallback" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    inline for (std.enums.values(store_testing.EffortMigrationChoice)) |choice| inline for ([_]bool{ false, true }) |legacy_codec| {
        const name = "{[effort]s}";
        try setupNamed("DROP DATABASE IF EXISTS " ++ name ++ ";CREATE DATABASE " ++ name);
        defer restoreNamed("DROP DATABASE IF EXISTS " ++ name);
        try load(name, store_testing.baseline_mysql_ddl, false);
        try load(name, store_testing.baseline_rows, true);
        inline for (schema.migrations) |step| {
            if (comptime step.from < 65) try load(name, schema.mysqlMigration(step.from), false);
        }
        try load(name, store_testing.operation_effort_migration_seed, false);
        try load(name, choice.sql(), false);
        if (legacy_codec) try load(name, "UPDATE session SET codec='openai-responses/1' WHERE session_ref='d8mv7p'", false);
        inline for (schema.migrations) |step| {
            if (comptime step.from >= 65) try load(name, schema.mysqlMigration(step.from), false);
        }
        var rows: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer rows.deinit();
        try writeResultNamed("SELECT operation_id,effort_source_revision,previous_reasoning_effort,effort_update FROM " ++ name ++ ".model_operation WHERE session_ref='d8mv7p' ORDER BY operation_id", &rows.writer);
        const source: u64 = if (choice == .retained) 2 else 3;
        const emitted = !legacy_codec and choice != .back_to_top;
        const expected = std.fmt.comptimePrint("\n 1:1 1:1 null 1:0\n 2:99 1:2 3:low 1:{d}\n 3:100 1:2 4:high 1:0\n 3:101 1:{d} 4:high 1:{d}", .{ @intFromBool(!legacy_codec), source, @intFromBool(emitted) });
        try std.testing.expectEqualStrings(expected, rows.written());
        if (choice == .legacy_new_choice) {
            try load(name, "INSERT INTO session_change(session_ref,position,ordinal,revision,field,changed_at,provider_text,refused_operation_id) VALUES('d8mv7p',30,0,2,'reasoning_effort_refused',1793781802,'refused',99)", false);
            rows.clearRetainingCapacity();
            try writeResultNamed(comptime "SELECT " ++ @import("domain/configuration.zig").reasoningEffortOverrideSql("s") ++ " FROM " ++ name ++ ".session s WHERE s.session_ref='d8mv7p'", &rows.writer);
            try std.testing.expectEqualStrings("\n 5:xhigh", rows.written());
        }
        done.migrations += 1;
        writeRecord();
    };
}

test "schema 75 MySQL pin migration handles fresh and historically upgraded kind checks" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    inline for (.{ false, true }) |historical| {
        try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql);
        try load(migrated_database_sql, store_testing.baseline_mysql_ddl, false);
        if (historical) try load(migrated_database_sql, store_testing.baseline_rows, true);
        inline for (schema.migrations) |step| {
            if (step.from < 74) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
        }
        if (!historical) {
            try load(migrated_database_sql, "DROP TABLE core_command", true);
            for (comptime schema.objects(.mysql)) |object| {
                if (!std.mem.eql(u8, object.name, "core_command") and !std.mem.eql(u8, object.name, "core_command_target_order")) continue;
                const text = try std.mem.replaceOwned(u8, std.testing.allocator, object.sql, "kind BETWEEN 1 AND 9", "kind BETWEEN 1 AND 6");
                defer std.testing.allocator.free(text);
                try load(migrated_database_sql, text, false);
            }
            // The expected fixture describes the current schema, while this Store is at format 74.
            const format_74_rows = comptime blk: {
                const current = store_testing.expected_mysql_rows;
                const baseline = store_testing.baseline_rows;
                const start = std.mem.indexOf(u8, current, "INSERT INTO message_admission(").?;
                const end = start + std.mem.indexOf(u8, current[start..], ";\n").? + 2;
                const old_start = std.mem.indexOf(u8, baseline, "INSERT INTO message_admission(").?;
                const old_end = old_start + std.mem.indexOf(u8, baseline[old_start..], ";\n").? + 2;
                break :blk current[0..start] ++ baseline[old_start..old_end] ++ current[end..];
            };
            try load(migrated_database_sql, format_74_rows, true);
        }
        try load(migrated_database_sql, "CREATE TEMPORARY TABLE original_pin_commands AS SELECT * FROM core_command", false);
        defer restoreNamed("DROP TEMPORARY TABLE " ++ migrated_database_sql ++ ".original_pin_commands");
        try load(migrated_database_sql, "CREATE TEMPORARY TABLE original_pin_stops AS SELECT * FROM session_stop", false);
        defer restoreNamed("DROP TEMPORARY TABLE " ++ migrated_database_sql ++ ".original_pin_stops");
        inline for (schema.migrations) |step| {
            if (step.from >= 74) try load(migrated_database_sql, schema.mysqlMigration(step.from), false);
        }
        try expectCatalog(migrated_database_sql);
        try expectSameResults(&.{
            "SELECT * FROM core_command ORDER BY command_seq",
            "SELECT command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused FROM session_stop ORDER BY command_key",
            "SELECT count(*) FROM session_pin",
            "SELECT count(*) FROM session_pin_command",
        }, &.{
            "SELECT * FROM original_pin_commands ORDER BY command_seq",
            "SELECT command_key,session_ref,selected_turn_id,position,admission_cutoff,stopped_at,parent_caused FROM original_pin_stops ORDER BY command_key",
            "SELECT 0",
            "SELECT 0",
        });
        try expectSameResults(&.{"SELECT count(*) FROM session_stop WHERE action_cutoff<>0"}, &.{"SELECT 0"});
        try load(migrated_database_sql, "INSERT INTO core_command(command_key,kind,target,input_digest,accepted,code,revision,created,command_seq) VALUES('pin-upgrade',7,'d8mv7p',UNHEX(REPEAT('00',32)),1,'',0,0,100);INSERT INTO session_pin_command(command_key,pinned) VALUES('pin-upgrade',1);INSERT INTO session_pin(session_ref,command_key) VALUES('d8mv7p','pin-upgrade');UPDATE session_pin SET command_key=NULL WHERE session_ref='d8mv7p'", false);
        try expectSameResults(&.{
            "SELECT count(*) FROM session_pin WHERE command_key IS NULL",
            "SELECT pinned FROM session_pin_command WHERE command_key='pin-upgrade'",
        }, &.{ "SELECT 1", "SELECT 1" });
        done.migrations += 1;
        writeRecord();
    }
}

test "schema 75 MySQL pin migration refuses absent and ambiguous kind checks before DDL" {
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    defer restoreNamed("USE " ++ database_sql);
    inline for (.{ false, true }) |ambiguous| {
        try setupNamed("DROP DATABASE IF EXISTS " ++ migrated_database_sql ++ ";CREATE DATABASE " ++ migrated_database_sql ++ ";USE " ++ migrated_database_sql);
        try setup("CREATE TABLE core_command(kind BIGINT CHECK(kind BETWEEN 1 AND 7))");
        if (ambiguous) try setup("ALTER TABLE core_command ADD CHECK(kind BETWEEN 1 AND 6), ADD CHECK(kind BETWEEN 1 AND 6)");
        const step = schema.migrations[74 - schema.migration_baseline];
        try setup("SET @rui_pin_kind_ddl='stale DDL must not survive refusal'");
        try setup(step.mysql[0]);
        if (ambiguous) {
            try std.testing.expect(try run(step.mysql[1]) != null);
        } else {
            try setup(step.mysql[1]);
            try std.testing.expect(try run(step.mysql[2]) != null);
        }
        try expectSameResults(&.{"SELECT @rui_pin_kind_ddl IS NULL"}, &.{"SELECT 1"});
        try expectSameResults(&.{
            "SELECT count(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='" ++ migrated_database_sql ++ "' AND TABLE_NAME IN ('session_pin','session_pin_command')",
            "SELECT count(*) FROM information_schema.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA='" ++ migrated_database_sql ++ "' AND TABLE_NAME='core_command' AND CONSTRAINT_TYPE='CHECK'",
        }, &.{ "SELECT 0", if (ambiguous) "SELECT 3" else "SELECT 1" });
    }
}

test "obligation projection MySQL row counts match SQLite for null changed unchanged missing and refused values" {
    const Projection = rsql.ObligationProjection(.{
        .sql = "SELECT session_ref,obligation_since AS saved_since,?2 AS owed_since FROM session WHERE session_ref=?1 UNION ALL " ++
            "SELECT session_ref,obligation_since AS saved_since,?3 AS owed_since FROM session WHERE session_ref=?1",
        .Args = struct { session: []const u8, owed: ?u64, other: ?u64 },
    });
    const io = std.testing.io;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    _ = connection() orelse return if (state == .absent) error.SkipZigTest else error.MysqlUnavailable;
    const name = "{[projection]s}";
    try setupNamed("DROP DATABASE IF EXISTS " ++ name ++ ";CREATE DATABASE " ++ name ++ ";USE " ++ name);
    defer restoreNamed("DROP DATABASE IF EXISTS " ++ name);
    defer restoreNamed("USE " ++ database_sql);
    const ddl_text = "CREATE TABLE session(session_ref VARCHAR(6) PRIMARY KEY,obligation_since BIGINT CHECK(obligation_since IS NULL OR obligation_since>0))";
    try setup(ddl_text);
    try setup("INSERT INTO session(session_ref,obligation_since) VALUES('aaaaaa',NULL),('bbbbbb',80)");
    try setup(comptime statements(prepareQuery(Projection.mysql.prepared()))[0]);
    defer restore("DEALLOCATE PREPARE rui_dialect_check");
    try std.testing.expectEqualDeep(@as([]const rsql.Slot, &.{ .{ .argument = 1 }, .{ .argument = 0 }, .{ .argument = 2 }, .{ .argument = 0 } }), Projection.mysql.slots);

    const Case = struct { saved: ?u64, owed: ?u64, other: ?u64 = null, missing: bool = false, rows: u64, expected: ?u64, refused: bool = false };
    const cases = [_]Case{
        .{ .saved = null, .owed = null, .rows = 0, .expected = null },
        .{ .saved = null, .owed = 17, .rows = 1, .expected = 17 },
        .{ .saved = 17, .owed = 17, .rows = 0, .expected = 17 },
        .{ .saved = 17, .owed = 31, .other = 9, .rows = 1, .expected = 9 },
        .{ .saved = null, .owed = null, .other = 17, .rows = 1, .expected = 17 },
        .{ .saved = 9, .owed = null, .rows = 1, .expected = null },
        .{ .saved = 17, .owed = 99, .missing = true, .rows = 0, .expected = 17 },
        .{ .saved = 17, .owed = 0, .rows = 0, .expected = 17, .refused = true },
    };
    try store_testing.expectSqliteObligationProjection(Projection.sql, ddl_text, cases);
    inline for (cases) |case| {
        const saved = if (case.saved) |n| std.fmt.comptimePrint("{d}", .{n}) else "NULL";
        const owed = if (case.owed) |n| std.fmt.comptimePrint("{d}", .{n}) else "NULL";
        const other = if (case.other) |n| std.fmt.comptimePrint("{d}", .{n}) else "NULL";
        const key = if (case.missing) "zzzzzz" else "aaaaaa";
        try setup("UPDATE session SET obligation_since=" ++ saved ++ " WHERE session_ref='aaaaaa'");
        try setup("SET @rui_projection_key='" ++ key ++ "',@rui_projection_owed=" ++ owed ++ ",@rui_projection_other=" ++ other);
        if (case.refused) {
            const refusal = (try run("EXECUTE rui_dialect_check USING @rui_projection_owed,@rui_projection_key,@rui_projection_other,@rui_projection_key")) orelse return error.MissingProjectionRefusal;
            try std.testing.expectEqual(@as(u16, 3819), refusal.code);
        } else {
            var counted: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer counted.deinit();
            try writeResult("EXECUTE rui_dialect_check USING @rui_projection_owed,@rui_projection_key,@rui_projection_other,@rui_projection_key;SELECT ROW_COUNT()", &counted.writer);
            try std.testing.expectEqualStrings(std.fmt.comptimePrint("\n 1:{d}", .{case.rows}), counted.written());
        }
        var retained: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer retained.deinit();
        try writeResult("SELECT session_ref,obligation_since FROM session ORDER BY session_ref", &retained.writer);
        const expected = if (case.expected) |n| std.fmt.comptimePrint(" {d}:{d}", .{ std.fmt.comptimePrint("{d}", .{n}).len, n }) else " null";
        try std.testing.expectEqualStrings("\n 6:aaaaaa" ++ expected ++ "\n 6:bbbbbb 2:80", retained.written());
    }
}
