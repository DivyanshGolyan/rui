//! Live Store fixtures. Only the fixture root connection performs DDL or DELETE.
const std = @import("std");
const Store = @import("Store.zig").Store;
const testing = @import("testing.zig");
const schema = @import("schema.zig");
const sqlite = @import("sqlite.zig");
const wire = @import("wire/mysql_connection.zig");
const literal = @import("mysql_literal.zig");
const rows = @import("mysql_row.zig");
const rsql = @import("rsql.zig");
const protocol = @import("../protocol.zig");
const change_ring = @import("../change_ring.zig");
const dialect = @import("mysql_dialect_check.zig");
var mutex: std.Io.Mutex = .init;
var root: wire.Connection = undefined;
var opened = false;

pub fn available() !bool {
    return (try dialect.rootConfig()) != null;
}

fn connection() !*wire.Connection {
    if (!opened) {
        const config = try dialect.rootConfig() orelse return error.MysqlRequired;
        var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer refusal.deinit();
        try root.open(.{ .address = .{ .unix_socket = config.socket }, .user = "root", .password = config.password, .database = "mysql" }, &refusal.writer);
        opened = true;
        for (schema.mysql_session) |sql| try run(sql);
        // Population fixtures deliberately exceed MySQL's default 1000 rows.
        try run("SET SESSION cte_max_recursion_depth=1000000");
    }
    return &root;
}

fn drain() !void {
    var failed = false;
    while (!root.isReady()) switch (try root.next()) {
        .err => |err| {
            std.debug.print("MySQL fixture error {d}: {s}\n", .{ err.code, err.message });
            failed = true;
        },
        else => {},
    };
    if (failed) return error.MysqlFixtureFailed;
}

fn run(sql: []const u8) !void {
    try root.query(sql);
    try drain();
}

fn database(storage: *Store) []const u8 {
    return std.mem.sliceTo(&storage.engine.mysql.state.testing_database, 0);
}

fn use(storage: *Store) !void {
    _ = try connection();
    var buffer: [80]u8 = undefined;
    try run(try std.fmt.bufPrint(&buffer, "USE {s}", .{database(storage)}));
}

pub fn open(storage: *Store, tmp: *std.testing.TmpDir, io: std.Io, options: testing.TestingStoreOptions) !void {
    var path_buffer: [protocol.max_store_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(io, &path_buffer);
    const path = path_buffer[0..length];
    const hash = std.hash.Wyhash.hash(0, path);
    var name_buffer: [40]u8 = @splat(0);
    const name = try std.fmt.bufPrint(name_buffer[0..39], "rui_test_{x:0>16}", .{hash});
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        _ = try connection();
        var buffer: [512]u8 = undefined;
        // IF NOT EXISTS preserves the same Store on a reopen of this tmp path.
        try run(try std.fmt.bufPrint(&buffer, "CREATE DATABASE IF NOT EXISTS {s};USE {s}", .{ name, name }));
        try root.query("SHOW TABLES");
        var exists = false;
        while (!root.isReady()) switch (try root.next()) {
            .row => exists = true,
            .err => return error.MysqlFixtureFailed,
            else => {},
        };
        if (!exists) {
            for (comptime schema.objects(.mysql)) |object| try run(object.sql);
            try run(try std.fmt.bufPrint(&buffer, "CREATE DATABASE {s}_oracle;CREATE TABLE {s}_oracle.touched_oracle(session_ref VARCHAR(6))", .{ name, name }));
            // Trigger names live in the Store schema; their root definer can
            // write the sibling schema without enlarging the app's grants.
            inline for (comptime sqlite.touchOracleTriggers(.mysql, "ORACLE.touched_oracle")) |sql| {
                var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer text.deinit();
                // Some trigger bodies insert twice: replace every qualifier.
                var rest: []const u8 = sql;
                while (std.mem.indexOf(u8, rest, "ORACLE")) |offset| {
                    try text.writer.writeAll(rest[0..offset]);
                    try text.writer.print("{s}_oracle", .{name});
                    rest = rest[offset + "ORACLE".len ..];
                }
                try text.writer.writeAll(rest);
                try run(text.written());
            }
            try run("CREATE USER IF NOT EXISTS 'rui_conformance'@'localhost' IDENTIFIED BY 'rui_conformance'");
            try run(try std.fmt.bufPrint(&buffer, "GRANT SELECT,INSERT,UPDATE ON {s}.* TO 'rui_conformance'@'localhost'", .{name}));
        }
    }
    const config = (try dialect.rootConfig()).?;
    try storage.openMysql(io, .{ .address = .{ .unix_socket = config.socket }, .user = "rui_conformance", .password = "rui_conformance", .database = name }, options.identity orelse path, .{ .served = options.served, .catalog = options.catalog });
    storage.engine.mysql.state.testing_database = name_buffer;
}

fn FixtureArgs(comptime T: type) type {
    const fields = @typeInfo(T).@"struct".field_types;
    var types: [fields.len]type = undefined;
    for (fields, 0..) |Field, index| types[index] = if (Field == testing.Blob) rsql.Bytes else switch (@typeInfo(Field)) {
        .comptime_int => i64,
        .pointer => []const u8,
        else => Field,
    };
    return @Tuple(&types);
}

fn send(comptime sql: []const u8, fixture_args: anytype) !void {
    var args: FixtureArgs(@TypeOf(fixture_args)) = undefined;
    inline for (fixture_args, 0..) |value, index| {
        args[index] = if (@TypeOf(value) == testing.Blob) .{ .bytes = value.bytes } else value;
    }
    const template = comptime switch (rsql.mysqlRendering(sql)) {
        .rendered => |value| value,
        .refused => |message| @compileError(message),
    };
    const Args = @TypeOf(args);
    const served = protocol.routesAll(.endpoint);
    const bound: literal.Bound = .{ .now = 0, .served = &served };
    const length = try literal.length(template, Args, &args, bound);
    const writer = try root.beginQuery(length);
    literal.write(template, Args, &args, bound, writer) catch {};
    try root.endQuery();
}

pub fn exec(storage: *Store, comptime sql: []const u8, args: anytype) !void {
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);
    try use(storage);
    try send(sql, args);
    try drain();
}

pub fn queryU64(storage: *Store, comptime sql: []const u8, args: anytype) !u64 {
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);
    try use(storage);
    try send(sql, args);
    const Row = struct { value: u64 };
    var columns: rows.Columns(Row) = undefined;
    var result: ?u64 = null;
    while (!root.isReady()) switch (try root.next()) {
        .columns => |n| columns = try rows.readColumns(Row, &root, n),
        .row => {
            var row: Row = undefined;
            try rows.decodeRow(Row, &columns, &root, &row);
            if (result == null) result = row.value;
        },
        .err => return error.QueryFailed,
        else => {},
    };
    return result orelse error.QueryFailed;
}

pub fn clearTouchOracleForTesting(storage: *Store) void {
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);
    _ = connection() catch @panic("touch oracle connection failed");
    var buffer: [128]u8 = undefined;
    run(std.fmt.bufPrint(&buffer, "DELETE FROM {s}_oracle.touched_oracle", .{database(storage)}) catch unreachable) catch @panic("touch oracle clear failed");
}

pub fn untouchedForTesting(storage: *Store, touched: *const change_ring.Touched) ?change_ring.Id {
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);
    _ = connection() catch @panic("touch oracle connection failed");
    var buffer: [160]u8 = undefined;
    root.query(std.fmt.bufPrint(&buffer, "SELECT DISTINCT session_ref FROM {s}_oracle.touched_oracle WHERE session_ref IS NOT NULL", .{database(storage)}) catch unreachable) catch @panic("touch oracle query failed");
    const Row = struct { session: @import("../bounded.zig").Bounded(6) };
    var columns: rows.Columns(Row) = undefined;
    var missing: ?change_ring.Id = null;
    while (!root.isReady()) switch (root.next() catch @panic("touch oracle read failed")) {
        .columns => |n| columns = rows.readColumns(Row, &root, n) catch @panic("touch oracle columns failed"),
        .row => {
            var row: Row = undefined;
            rows.decodeRow(Row, &columns, &root, &row) catch @panic("touch oracle row failed");
            if (!touched.contains(row.session.slice())) {
                var id: change_ring.Id = @splat('?');
                @memcpy(id[0..row.session.len], row.session.slice());
                missing = id;
            }
        },
        .err => @panic("touch oracle refused"),
        else => {},
    };
    return missing;
}

/// Fixture-only server controls: never called by the application login.
pub fn rawExec(storage: *Store, sql: []const u8) !void {
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);
    try use(storage);
    try run(sql);
}

fn globalValue(comptime name: []const u8) !protocol.Bounded(32) {
    try root.query("SELECT @@global." ++ name);
    const Row = struct { value: protocol.Bounded(32) };
    var columns: rows.Columns(Row) = undefined;
    var result: ?protocol.Bounded(32) = null;
    while (!root.isReady()) switch (try root.next()) {
        .columns => |n| columns = try rows.readColumns(Row, &root, n),
        .row => {
            var row: Row = undefined;
            try rows.decodeRow(Row, &columns, &root, &row);
            result = row.value;
        },
        .err => return error.MysqlFixtureFailed,
        else => {},
    };
    return result orelse error.MysqlFixtureFailed;
}

fn setGlobal(comptime name: []const u8, value: []const u8) !void {
    // Values come only from this server's own numeric/enum variables, or
    // the fixed probes below, not from test/user SQL.
    var buffer: [160]u8 = undefined;
    try run(try std.fmt.bufPrint(&buffer, "SET GLOBAL " ++ name ++ "='{s}'", .{value}));
}

/// The mutex spans mutation, refusal and restoration. A failed assertion
/// restores the exact original settings too; super_read_only also changes
/// read_only, so both are saved and restored for that probe.
fn refusesGlobal(comptime name: []const u8, bad: []const u8, expected: anyerror) !void {
    const config = try dialect.rootConfig() orelse return error.SkipZigTest;
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);
    _ = try connection();
    const old = try globalValue(name);
    const old_read_only = try globalValue("read_only");
    const old_super_read_only = try globalValue("super_read_only");
    defer {
        if (comptime std.mem.eql(u8, name, "super_read_only")) {
            setGlobal("super_read_only", "0") catch @panic("cannot restore super_read_only");
            setGlobal("read_only", old_read_only.slice()) catch @panic("cannot restore read_only");
            setGlobal("super_read_only", old_super_read_only.slice()) catch @panic("cannot restore super_read_only");
        } else setGlobal(name, old.slice()) catch @panic("cannot restore MySQL global");
    }
    try setGlobal(name, bad);
    const probe = try std.testing.allocator.create(wire.Connection);
    defer std.testing.allocator.destroy(probe);
    var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refusal.deinit();
    try probe.open(.{ .address = .{ .unix_socket = config.socket }, .user = "root", .password = config.password, .database = "mysql" }, &refusal.writer);
    defer probe.close();
    try std.testing.expectError(expected, @import("engine/mysql_open.zig").open(probe, std.testing.io, .{ .database = "mysql" }, "/mysql-refusal-probe"));
}
