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
const os = @import("../os/os.zig");
const change_ring = @import("../change_ring.zig");
const dialect = @import("mysql_dialect_check.zig");
var mutex: std.Io.Mutex = .init;
var root: wire.Connection = undefined;
var opened = false;
const Database = struct {
    name: [40]u8,
    path: []u8,
    dirty: bool = false,
};
var databases: std.ArrayList(Database) = .empty;

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

fn drain(source: anytype, changes: ?*i64) !void {
    var failed = false;
    while (!source.isReady()) switch (try source.next()) {
        .ok => |ok| if (changes) |count| {
            count.* +|= @intCast(@min(ok.affected_rows, std.math.maxInt(i64)));
        },
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
    try drain(&root, null);
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
    const name_buffer = name: {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        _ = try connection();
        for (databases.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) break :name entry.name;
        }
        const owned_path = try std.heap.page_allocator.dupe(u8, path);
        errdefer std.heap.page_allocator.free(owned_path);
        var buffer: [512]u8 = undefined;
        for (databases.items) |*entry| {
            if (entry.dirty) continue;
            if (std.Io.Dir.cwd().access(io, entry.path, .{})) |_| {
                continue;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
            const database_name = std.mem.sliceTo(&entry.name, 0);
            try root.query(try std.fmt.bufPrint(&buffer, "SELECT IS_USED_LOCK('{s}') IS NULL", .{database_name}));
            if (try readU64() == 0) continue;
            entry.dirty = true;
            try empty(database_name);
            std.heap.page_allocator.free(entry.path);
            entry.path = owned_path;
            entry.dirty = false;
            break :name entry.name;
        }
        try databases.ensureUnusedCapacity(std.heap.page_allocator, 1);
        const hash = std.hash.Wyhash.hash(0, path);
        var fresh_name: [40]u8 = @splat(0);
        const name = try std.fmt.bufPrint(fresh_name[0..39], "rui_test_{x:0>16}", .{hash});
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
        databases.appendAssumeCapacity(.{ .name = fresh_name, .path = owned_path });
        break :name fresh_name;
    };
    const name = std.mem.sliceTo(&name_buffer, 0);
    const config = (try dialect.rootConfig()).?;
    try storage.openTarget(io, .{ .mysql = .{ .address = .{ .unix_socket = config.socket }, .user = "rui_conformance", .password = "rui_conformance", .database = name } }, options.identity orelse path, .{ .served = options.served, .host_tool_set = options.host_tool_set });
    storage.engine.mysql.state.testing_database = name_buffer;
}

fn empty(name: []const u8) !void {
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try text.writer.print("USE {s};SET foreign_key_checks=0;", .{name});
    for (comptime schema.objects(.mysql)) |object| {
        if (object.kind == .table) try text.writer.print("DELETE FROM {s};", .{object.name});
    }
    // DELETE fires the touch-oracle triggers, so clear their rows last.
    try text.writer.print("DELETE FROM {s}_oracle.touched_oracle;SET foreign_key_checks=1", .{name});
    errdefer run("SET foreign_key_checks=1") catch @panic("foreign keys stayed off");
    try run(text.written());
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
    // SQLite fixtures write through the Store connection, so totalChanges
    // sees them. Attribute this fixture's write OKs to the target Store too,
    // including writes preceding a later ERR; setup/control queries stay out.
    try drain(&root, &storage.engine.mysql.state.changes);
}

pub fn queryU64(storage: *Store, comptime sql: []const u8, args: anytype) !u64 {
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);
    try use(storage);
    try send(sql, args);
    return readU64();
}

fn readU64() !u64 {
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
    for (databases.items) |*entry| {
        if (std.mem.eql(u8, std.mem.sliceTo(&entry.name, 0), database(storage))) entry.dirty = true;
    }
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
    // A boolean variable such as read_only takes 1 or 0 but refuses the
    // string '1' (error 1231), so numbers go unquoted.
    const numeric = value.len != 0 and for (value) |c| {
        if (!std.ascii.isDigit(c)) break false;
    } else true;
    var buffer: [160]u8 = undefined;
    try run(if (numeric)
        try std.fmt.bufPrint(&buffer, "SET GLOBAL " ++ name ++ "={s}", .{value})
    else
        try std.fmt.bufPrint(&buffer, "SET GLOBAL " ++ name ++ "='{s}'", .{value}));
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

test "store.mysql fixture drain attributes write OKs even before failure" {
    const Script = struct {
        events: []const wire.mysql.Event,
        at: usize = 0,

        fn isReady(self: *const @This()) bool {
            return self.at == self.events.len;
        }

        fn next(self: *@This()) error{ConnectionLost}!wire.mysql.Event {
            const event = self.events[self.at];
            self.at += 1;
            return event;
        }
    };
    const status: wire.mysql.Status = @bitCast(@as(u16, 0));
    var changes: i64 = 10;
    var success: Script = .{ .events = &.{
        .{ .ok = .{ .affected_rows = 0, .status = status } },
        .{ .ok = .{ .affected_rows = 2, .status = status } },
        .{ .rows_end = status },
        .{ .ok = .{ .affected_rows = 3, .status = status } },
        .ready,
    } };
    try drain(&success, &changes);
    try std.testing.expectEqual(@as(i64, 15), changes);
    try std.testing.expect(success.isReady());

    var failure: Script = .{ .events = &.{
        .{ .ok = .{ .affected_rows = 4, .status = status } },
        .{ .err = .{ .code = 1062, .sql_state = "23000".*, .message = "expected duplicate" } },
        .ready,
    } };
    try std.testing.expectError(error.MysqlFixtureFailed, drain(&failure, &changes));
    try std.testing.expectEqual(@as(i64, 19), changes);
    try std.testing.expect(failure.isReady());

    var uncounted = success;
    uncounted.at = 0;
    try drain(&uncounted, null);
    try std.testing.expectEqual(@as(i64, 19), changes);

    var overflow: Script = .{ .events = &.{
        .{ .ok = .{ .affected_rows = std.math.maxInt(u64), .status = status } },
        .{ .ok = .{ .affected_rows = 1, .status = status } },
    } };
    try drain(&overflow, &changes);
    try std.testing.expectEqual(std.math.maxInt(i64), changes);
}

test "store.mysql live open preserves a refused login" {
    const config = try dialect.rootConfig() orelse return error.SkipZigTest;
    var wrong: [32]u8 = undefined;
    std.testing.io.random(&wrong);
    const password = std.fmt.bytesToHex(wrong, .lower);
    try std.testing.expectError(error.LoginRefused, Mysql.open(std.testing.io, .{
        .address = .{ .unix_socket = config.socket },
        .user = "root",
        .password = &password,
        .database = "mysql",
    }, "/mysql-refusal-probe", .{}));
}

test "store.mysql open preserves an unreachable socket" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(std.testing.io, &directory);
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const missing = try std.fmt.bufPrint(&path, "{s}/missing.sock", .{directory[0..length]});
    try std.testing.expectError(error.ConnectFailed, Mysql.open(std.testing.io, .{
        .address = .{ .unix_socket = missing },
        .user = "root",
        .password = "not-sent",
        .database = "mysql",
    }, "/mysql-refusal-probe", .{}));
}

/// Admission under the fixture's SELECT/INSERT/UPDATE-only runtime grant.
fn admitMetadata(name: []const u8, selector: []const u8) !Mysql {
    const config = (try dialect.rootConfig()).?;
    return Mysql.open(std.testing.io, .{
        .address = .{ .unix_socket = config.socket },
        .user = "rui_conformance",
        .password = "rui_conformance",
        .database = name,
    }, selector, .{});
}

fn refusesMetadata(name: []const u8, selector: []const u8, expected: anyerror) !void {
    const admission = admitMetadata(name, selector);
    if (admission) |engine| {
        var admitted = engine;
        try admitted.close();
    } else |_| {}
    try std.testing.expectError(expected, admission);
    // Refusal closes an undrained connection. COM_QUIT/socket close releases
    // GET_LOCK when the server finishes that session, not at local return.
    // Observe that boundary before the next probe, without a timing delay.
    var buffer: [128]u8 = undefined;
    try root.query(try std.fmt.bufPrint(&buffer, "SELECT GET_LOCK('{s}',10)", .{name}));
    try std.testing.expectEqual(@as(u64, 1), try readU64());
    try run("DO RELEASE_ALL_LOCKS()");
}

test "store.mysql live metadata validates canonical identity independently of a renamed database" {
    var original_tmp = std.testing.tmpDir(.{});
    defer original_tmp.cleanup();
    var restored_tmp = std.testing.tmpDir(.{});
    defer restored_tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &original_tmp);
    const original_name = storage.engine.mysql.state.testing_database;
    const id = storage.engine.mysql.state.store_id;
    const selector = storage.selector;
    try storage.close();
    try openLive(&storage, &restored_tmp);
    const restored_name = storage.engine.mysql.state.testing_database;
    try storage.close();
    const name = std.mem.sliceTo(&original_name, 0);
    const restored = std.mem.sliceTo(&restored_name, 0);
    try std.testing.expect(!std.mem.eql(u8, name, restored));
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);
    var buffer: [1024]u8 = undefined;
    try run(try std.fmt.bufPrint(&buffer, "USE {s}", .{name}));
    // Missing selectors are repaired atomically; the id never changes.
    // Exercise SQL metacharacters and UTF-8 through the actual repair path.
    const canonical = "/canonical/'\\é";
    try run("DELETE FROM store_meta WHERE meta_key='store_selector'");
    var repaired = try admitMetadata(name, canonical);
    try std.testing.expectEqualStrings(&id, &repaired.state.store_id);
    try repaired.close();
    var reopened = try admitMetadata(name, canonical);
    try std.testing.expectEqualStrings(&id, &reopened.state.store_id);
    try reopened.close();
    try refusesMetadata(name, selector.slice(), error.WrongStoreIdentity);
    for ([_][]const u8{
        "UPDATE store_meta SET meta_value='different-database' WHERE meta_key='store_selector'",
        "UPDATE store_meta SET meta_value=REPEAT('x',600) WHERE meta_key='store_selector'",
    }) |change| {
        try run(change);
        try refusesMetadata(name, canonical, error.WrongStoreIdentity);
    }
    // A database rename is independent of canonical identity: restoring the
    // same metadata under a new database name keeps both selector and id.
    try run("DELETE FROM store_meta WHERE meta_key='store_selector'");
    var matching = try admitMetadata(name, canonical);
    try matching.close();
    try run(try std.fmt.bufPrint(
        &buffer,
        "DELETE FROM {s}.store_meta;INSERT INTO {s}.store_meta SELECT * FROM store_meta;DELETE FROM {s}.store_owner;INSERT INTO {s}.store_owner SELECT * FROM store_owner",
        .{ restored, restored, restored, restored },
    ));
    try refusesMetadata(restored, restored, error.WrongStoreIdentity);
    var admitted = try admitMetadata(restored, canonical);
    defer admitted.close() catch unreachable;
    try std.testing.expectEqualStrings(&id, &admitted.state.store_id);
}

test "store.mysql live metadata failures precede missing-key repair and ownership writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    const name_buffer = storage.engine.mysql.state.testing_database;
    const name = std.mem.sliceTo(&name_buffer, 0);
    const selector = storage.selector;
    try storage.close();
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);
    var buffer: [512]u8 = undefined;
    try run(try std.fmt.bufPrint(&buffer, "USE {s}", .{name}));
    const cases = .{
        .{ "UPDATE store_meta SET meta_value='0' WHERE meta_key='format'", error.StoreSchemaBehind },
        .{ std.fmt.comptimePrint("UPDATE store_meta SET meta_value='{d}' WHERE meta_key='format'", .{schema.schema_version + 1}), error.StoreSchemaAhead },
        .{ "UPDATE store_meta SET meta_value='not-a-number' WHERE meta_key='format'", error.MalformedStoreFormat },
        .{ "UPDATE store_meta SET meta_value=REPEAT('9',600) WHERE meta_key='format'", error.MalformedStoreFormat },
        .{ "UPDATE store_meta SET meta_value='13' WHERE meta_key='wire_version'", error.WrongStoreVersion },
        .{ "UPDATE store_meta SET meta_value='wrong-wire' WHERE meta_key='wire_version'", error.WrongStoreVersion },
        .{ "UPDATE store_meta SET meta_value=REPEAT('9',600) WHERE meta_key='wire_version'", error.WrongStoreVersion },
        .{ "INSERT INTO store_meta VALUES('store_id','not-an-id')", error.WrongStoreIdentity },
        .{ "INSERT INTO store_meta VALUES('store_id',REPEAT('a',600))", error.WrongStoreIdentity },
        .{ "UPDATE store_meta SET meta_value='different' WHERE meta_key='store_selector'", error.WrongStoreIdentity },
        .{ "UPDATE store_meta SET meta_value=REPEAT('x',600) WHERE meta_key='store_selector'", error.WrongStoreIdentity },
        .{ "INSERT INTO store_meta VALUES('unexpected','private-value')", error.WrongStoreSchema },
    };
    inline for (cases) |case| {
        try run("DELETE FROM store_meta WHERE meta_key='store_id' OR meta_key='unexpected';" ++
            "UPDATE store_meta SET meta_value='" ++ std.fmt.comptimePrint("{d}", .{schema.schema_version}) ++ "' WHERE meta_key='format';" ++
            "UPDATE store_meta SET meta_value='" ++ @import("../wire_version.zig").wire_version ++ "' WHERE meta_key='wire_version'");
        try run("DELETE FROM store_meta WHERE meta_key='store_selector'");
        var baseline = try admitMetadata(name, selector.slice());
        try baseline.close();
        try run("DELETE FROM store_meta WHERE meta_key='store_id'");
        const unexpected_key = case[1] == error.WrongStoreSchema;
        if (unexpected_key) try run("ALTER TABLE store_meta ALTER CHECK store_meta_chk_1 NOT ENFORCED");
        defer if (unexpected_key) {
            run("DELETE FROM store_meta WHERE meta_key='unexpected';ALTER TABLE store_meta ALTER CHECK store_meta_chk_1 ENFORCED") catch @panic("cannot restore metadata CHECK enforcement");
        };
        try run(case[0]);
        try root.query("SELECT epoch FROM store_owner WHERE owner_key=1");
        const epoch = try readU64();
        try root.query("SELECT BIT_XOR(CRC32(CONCAT(meta_key,'=',meta_value))) FROM store_meta");
        const before = try readU64();
        try refusesMetadata(name, selector.slice(), case[1]);
        try root.query("SELECT epoch FROM store_owner WHERE owner_key=1");
        try std.testing.expectEqual(epoch, try readU64());
        try root.query("SELECT BIT_XOR(CRC32(CONCAT(meta_key,'=',meta_value))) FROM store_meta");
        try std.testing.expectEqual(before, try readU64());
    }
    try run("DELETE FROM store_meta WHERE meta_key='unexpected'");
}

test "store.mysql live metadata repair rolls back with a refused ownership update" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    const name_buffer = storage.engine.mysql.state.testing_database;
    const name = std.mem.sliceTo(&name_buffer, 0);
    const epoch = storage.engine.mysql.state.epoch;
    try storage.close();
    mutex.lockUncancelable(std.testing.io);
    defer mutex.unlock(std.testing.io);
    var buffer: [128]u8 = undefined;
    try run(try std.fmt.bufPrint(&buffer, "USE {s}", .{name}));
    try run("DELETE FROM store_meta;CREATE TRIGGER refuse_owner_update BEFORE UPDATE ON store_owner FOR EACH ROW SIGNAL SQLSTATE '45000'");
    {
        defer run("DROP TRIGGER refuse_owner_update") catch @panic("cannot restore ownership updates");
        try refusesMetadata(name, name, error.StatementFailed);
        try root.query("SELECT count(*) FROM store_meta");
        try std.testing.expectEqual(@as(u64, 0), try readU64());
        try root.query("SELECT epoch FROM store_owner WHERE owner_key=1");
        try std.testing.expectEqual(epoch, try readU64());
    }
    var repaired = try admitMetadata(name, name);
    const id = repaired.state.store_id;
    try std.testing.expect(schema.isStoreId(&id));
    try std.testing.expectEqual(epoch + 1, repaired.state.epoch);
    try repaired.close();
    try root.query("SELECT count(*) FROM store_meta");
    try std.testing.expectEqual(@as(u64, 4), try readU64());
    var reopened = try admitMetadata(name, name);
    defer reopened.close() catch unreachable;
    try std.testing.expectEqualStrings(&id, &reopened.state.store_id);
}

test "store.mysql live admission checks the index plan domain without pinning generated key names" {
    const Alter = struct {
        fn index(name: []const u8, comptime table: []const u8, comptime alteration: []const u8) !void {
            mutex.lockUncancelable(std.testing.io);
            defer mutex.unlock(std.testing.io);
            _ = try connection();
            var buffer: [512]u8 = undefined;
            try run(try std.fmt.bufPrint(&buffer, "ALTER TABLE {s}." ++ table ++ " " ++ alteration, .{name}));
        }

        fn refuses(name: []const u8, tmp: *std.testing.TmpDir, comptime table: []const u8, comptime alteration: []const u8, comptime restoration: []const u8, epoch: *u64) !void {
            try index(name, table, alteration);
            {
                defer index(name, table, restoration) catch @panic("cannot restore index plan property");
                var refused: Store = undefined;
                // A mutation that admits the Store must still close its lock.
                const admission = open(&refused, tmp, std.testing.io, .{});
                if (admission) |_| try refused.close() else |_| {}
                try std.testing.expectError(error.StoreCatalogMismatch, admission);
            }
            // Restoring only the altered property repairs admission; no
            // migration is needed, and the refused open released GET_LOCK.
            var repaired: Store = undefined;
            try openLive(&repaired, tmp);
            defer repaired.close() catch unreachable;
            try std.testing.expectEqual(epoch.* + 1, repaired.engine.mysql.state.epoch);
            epoch.* = repaired.engine.mysql.state.epoch;
            try std.testing.expectEqual(@as(u64, 1), try liveWrite(&repaired, live_noop, .{}));
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    const name_buffer = storage.engine.mysql.state.testing_database;
    const name = std.mem.sliceTo(&name_buffer, 0);
    var epoch = storage.engine.mysql.state.epoch;
    try storage.close();

    inline for (schema.indexes) |index| {
        inline for (.{
            .{ .alter = "RENAME INDEX " ++ index.name ++ " TO renamed_probe", .restore = "RENAME INDEX renamed_probe TO " ++ index.name, .forceable_only = true },
            .{ .alter = "ALTER INDEX " ++ index.name ++ " INVISIBLE", .restore = "ALTER INDEX " ++ index.name ++ " VISIBLE", .forceable_only = false },
        }) |change| {
            if (comptime !change.forceable_only or schema.mysqlCanForceIndex(index.name))
                try Alter.refuses(name, &tmp, index.table, change.alter, change.restore, &epoch);
        }
    }
    // A prefix preserves the name, columns, order, uniqueness and type but
    // loses covering bytes. It must not be mistaken for the full-column key.
    try Alter.refuses(name, &tmp, "session", "DROP INDEX session_workspace_list, ADD INDEX session_workspace_list(workspace_digest(1),created_seq)", "DROP INDEX session_workspace_list, ADD INDEX session_workspace_list(workspace_digest,created_seq)", &epoch);

    // MySQL names these keys itself: a unique constraint and an FK-backing
    // index. Lowered partial indexes are likewise never forced by name.
    inline for (.{
        .{ "content", "digest" },
        .{ "session_revision", "instructions_content_id" },
        .{ "session_stop", "session_stop_unpositioned" },
        .{ "turn", "turn_one_active_per_session" },
    }) |key| {
        try Alter.refuses(name, &tmp, key[0], "ALTER INDEX " ++ key[1] ++ " INVISIBLE", "ALTER INDEX " ++ key[1] ++ " VISIBLE", &epoch);
        try Alter.index(name, key[0], "RENAME INDEX " ++ key[1] ++ " TO renamed_probe");
        defer Alter.index(name, key[0], "RENAME INDEX renamed_probe TO " ++ key[1]) catch @panic("cannot restore unforced index name");
        try openLive(&storage, &tmp);
        epoch = storage.engine.mysql.state.epoch;
        try storage.close();
    }
}

test "store.mysql live admission refuses read_only" {
    try refusesGlobal("read_only", "1", error.MysqlReadOnly);
}

test "store.mysql live admission refuses super_read_only" {
    try refusesGlobal("super_read_only", "1", error.MysqlReadOnly);
}

test "store.mysql live admission refuses weak InnoDB commit flush" {
    try refusesGlobal("innodb_flush_log_at_trx_commit", "2", error.MysqlFlushLogUnsafe);
}

test "store.mysql live admission refuses weak binlog sync" {
    // CI starts with log_bin enabled. log_bin itself is not dynamic, and
    // the pure refusal test covers the disabled-binlog combinations.
    try refusesGlobal("sync_binlog", "0", error.MysqlSyncBinlogUnsafe);
}

test "store.mysql live admission refuses statement binlogging" {
    try refusesGlobal("binlog_format", "STATEMENT", error.MysqlStatementBinlog);
}

const store_core = @import("Store.zig");
const store_access = @import("access.zig");
const transition = @import("transition.zig");
const Mysql = @import("engine/Mysql.zig");
const live_noop = rsql.Write(.{
    .sql = "UPDATE store_owner SET epoch=epoch WHERE owner_key=1",
    .Args = struct {},
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.LiveGuard } },
});
const live_guard = rsql.Write(.{
    .sql = "UPDATE store_owner SET commit_seq=commit_seq WHERE owner_key=1",
    .Args = struct {},
    .expect = .{ .exact = .{ .rows = 2, .otherwise = error.LiveGuard } },
});
const live_insert = rsql.Write(.{
    .sql = "INSERT INTO content(content_id,digest,byte_length,payload,private) VALUES(?1,?2,?3,zeroblob(?3),0)",
    .Args = struct { id: u64, digest: [32]u8, length: u64 = 0 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.LiveGuard } },
});

fn openLive(storage: *Store, tmp: *std.testing.TmpDir) !void {
    if (!try available()) return error.SkipZigTest;
    try open(storage, tmp, std.testing.io, .{});
}

/// One typed engine pass, retaining the application's restricted login.
fn liveWrite(storage: *Store, comptime S: type, args: S.Args) !u64 {
    const mysql = &storage.engine.mysql;
    try mysql.bind(S, &args, 0);
    try mysql.startPass();
    const changed = try mysql.stepWrite();
    mysql.endStatement();
    try mysql.finishPass();
    return changed;
}

test "Store target MySQL owns admitted identity routes and neutral diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    try std.testing.expectEqual(.mysql, storage.kind());
    const id = storage.engine.mysql.state.store_id;
    try std.testing.expectEqualStrings(&id, storage.storeId());
    try std.testing.expect(@import("../store_id.zig").valid(storage.storeId()));
    const diagnostic = storage.diagnostic();
    try std.testing.expect(diagnostic == .mysql);
    try std.testing.expectEqualStrings(diagnostic.mysql.doublewrite.slice(), storage.admissionDiagnostic().doublewrite.?);
    try std.testing.expect(storage.hostTools().set_id != 0);
    // The engine must borrow routes from final Store storage. The login and
    // selector buffers in the fixture's open function have already expired.
    try std.testing.expect(storage.engine.mysql.state.served == &storage.served);
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
}

test "Store target MySQL tail failure releases the connection and ownership lock" {
    if (!try available()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const empty_tool_set: @import("../tool_record.zig").HostToolSet = .{ .records = &.{}, .digests = &.{} };
    var refused: Store = undefined;
    try std.testing.expectError(error.InvalidHostToolSet, open(&refused, &tmp, std.testing.io, .{ .host_tool_set = &empty_tool_set }));
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    try std.testing.expect(storage.hostTools().set_id != 0);
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
}

test "store.mysql live CLIENT_FOUND_ROWS counts an unchanged matched UPDATE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const before = try queryU64(&storage, "SELECT epoch FROM store_owner WHERE owner_key=1", .{});
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
    try std.testing.expectEqual(before, try queryU64(&storage, "SELECT epoch FROM store_owner WHERE owner_key=1", .{}));
    try std.testing.expect(!storage.isFenced());
}

test "store.mysql live reused savepoint replaces its position and preserves earlier writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const mysql = &storage.engine.mysql;
    defer if (mysql.inTransaction()) mysql.control(.rollback) catch unreachable;
    try mysql.control(.begin);
    _ = try liveWrite(&storage, live_insert, .{ .id = 9000001, .digest = protocol.contentDigest("before-savepoint") });
    try mysql.control(.savepoint);
    _ = try liveWrite(&storage, live_insert, .{ .id = 9000002, .digest = protocol.contentDigest("before-replaced-savepoint") });
    try mysql.control(.savepoint);
    _ = try liveWrite(&storage, live_insert, .{ .id = 9000003, .digest = protocol.contentDigest("after-replaced-savepoint") });
    try mysql.control(.rollback_to);
    try mysql.control(.release);
    try mysql.control(.commit);
    try std.testing.expectEqual(@as(u64, 2), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id IN (9000001,9000002)", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000003", .{}));
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
    try std.testing.expect(!storage.isFenced());
}

test "store.mysql live first Access guard survives a later duplicate and keeps failedOn identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const duplicate: live_insert.Args = .{ .id = 9000010, .digest = protocol.contentDigest("duplicate-after-guard") };
    _ = try liveWrite(&storage, live_insert, duplicate);
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
    defer access.deinit();
    const queries_before = storage.engine.mysql.state.connection.queries;
    access.write(live_guard, .{});
    access.write(live_insert, duplicate);
    try std.testing.expectError(error.LiveGuard, access.run());
    // Distinct SQL pointers attribute the first client guard, not the
    // duplicate-key ERR drained from the second statement in the batch.
    try std.testing.expect(access.failedOn(live_guard));
    try std.testing.expect(!access.failedOn(live_insert));
    try std.testing.expectEqual(@as(u64, 1), storage.engine.mysql.state.connection.queries - queries_before);
    try access.abandon(.{});
    try std.testing.expect(!storage.engine.inTransaction());
    try std.testing.expect(storage.engine.mysql.state.connection.isReady());
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
    try std.testing.expect(!storage.isFenced());
}

test "store.mysql live abandoning an Access drains an already-sent large content chunk" {
    for ([_]bool{ false, true }) |duplicate| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try openLive(&storage, &tmp);
        defer storage.close() catch unreachable;
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
        defer access.deinit();
        // A batch as small as a server with small packets leaves, so a
        // chunk's INSERT streams as a statement of its own.
        const wire_connection = &storage.engine.mysql.state.connection;
        const limit = wire_connection.batch_limit;
        defer wire_connection.batch_limit = limit;
        wire_connection.batch_limit = 16 * 1024;
        const bytes = try std.testing.allocator.alloc(u8, 32 * 1024);
        defer std.testing.allocator.free(bytes);
        @memset(bytes, 'x');
        access.write(live_insert, .{ .id = 9000030, .digest = protocol.contentDigest(bytes), .length = bytes.len });
        try access.run();
        access.writeContent(9000030, bytes);
        if (duplicate) {
            // Resolve the first insert, then leave a duplicate-key ERR unread.
            // Discarding that ordinary statement error must still allow rollback.
            try access.run();
            access.writeContent(9000030, bytes);
        }
        // No pass after writeContent: bind has already sent the oversized query,
        // but Access has not read its response when the caller abandons the work.
        try std.testing.expect(storage.engine.mysql.state.long_query);
        try std.testing.expect(!storage.engine.mysql.state.connection.isReady());
        try access.abandon(.{});
        try std.testing.expect(!storage.engine.inTransaction());
        try std.testing.expect(storage.engine.mysql.state.connection.isReady());
        try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000030", .{}));
        try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content_chunk WHERE content_id=9000030", .{}));
        try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
        try std.testing.expect(!storage.isFenced());
    }
}

test "store.mysql live content chunks ride the round of their row, and a stop midchunk sends nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const length = @import("engine/mysql_content.zig").chunk_bytes + 17;
    const bytes = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'y');
    for ([_]bool{ false, true }) |stopped| {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
        defer access.deinit();
        const before = storage.engine.mysql.state.connection.queries;
        const id = try access.identity(.content_id);
        access.write(live_insert, .{ .id = id, .digest = protocol.contentDigest(bytes), .length = length });
        access.recordContentRow(id);
        const sink = try access.contentSink(id, length);
        if (stopped) {
            // The source stops here: close pads the chunk begun, and the
            // abandoned batch is never sent.
            try sink.write(bytes[0..7], 0);
            sink.close();
            const shape = storage.engine.mysql.state.testing_shape;
            try access.abandon(.{});
            // No batch and no ROLLBACK went out: only the identity reload
            // a rolled-back transaction that took ids costs.
            const after = storage.engine.mysql.state.testing_shape;
            try std.testing.expectEqual(shape.access_passes, after.access_passes);
            try std.testing.expectEqual(shape.controls, after.controls);
            try std.testing.expectEqual(before + 1, storage.engine.mysql.state.connection.queries);
            try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content_chunk WHERE content_id=?1", .{id}));
        } else {
            try sink.write(bytes, 0);
            sink.close();
            try access.commit();
            // The row, both chunks and the position checks in one round,
            // then COMMIT.
            try std.testing.expectEqual(before + 2, storage.engine.mysql.state.connection.queries);
            try std.testing.expectEqual(@as(u64, 2), try queryU64(&storage, "SELECT count(*) FROM content_chunk WHERE content_id=?1", .{id}));
            try std.testing.expectEqual(@as(u64, length), try queryU64(&storage, "SELECT sum(length(bytes)) FROM content_chunk WHERE content_id=?1", .{id}));
        }
    }
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
    try std.testing.expect(!storage.isFenced());
}

test "store.mysql live content chunks keep each batch within a small max_allowed_packet" {
    if (!try available()) return error.SkipZigTest;
    const old = old: {
        mutex.lockUncancelable(std.testing.io);
        defer mutex.unlock(std.testing.io);
        _ = try connection();
        const old = try globalValue("max_allowed_packet");
        try setGlobal("max_allowed_packet", "262144");
        break :old old;
    };
    defer {
        mutex.lockUncancelable(std.testing.io);
        defer mutex.unlock(std.testing.io);
        setGlobal("max_allowed_packet", old.slice()) catch @panic("cannot restore max_allowed_packet");
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    // A failed close must not skip restoring the server's packet limit.
    defer storage.close() catch {};
    // Each value's chunk fits a 256 KiB packet; the two together do not.
    const length = 64 * 1024;
    const bytes = try std.testing.allocator.alloc(u8, length);
    defer std.testing.allocator.free(bytes);
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
    defer access.deinit();
    errdefer access.abandon(.{}) catch {};
    const before = storage.engine.mysql.state.connection.queries;
    var ids: [2]u64 = undefined;
    for (&ids, 0..) |*id, i| {
        // Distinct values: content rows are unique by digest.
        @memset(bytes, 'a' + @as(u8, @intCast(i)));
        id.* = try access.identity(.content_id);
        access.write(live_insert, .{ .id = id.*, .digest = protocol.contentDigest(bytes), .length = length });
        access.recordContentRow(id.*);
        const sink = try access.contentSink(id.*, length);
        try sink.write(bytes, 0);
        sink.close();
    }
    try access.commit();
    // The first row and chunk, then the second row and chunk, then COMMIT.
    try std.testing.expectEqual(before + 3, storage.engine.mysql.state.connection.queries);
    for (ids) |id| try std.testing.expectEqual(@as(u64, length), try queryU64(&storage, "SELECT sum(length(bytes)) FROM content_chunk WHERE content_id=?1", .{id}));
    try std.testing.expect(!storage.isFenced());
}

test "store.mysql live every message carries the session settings, so none relies on the last" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const conn = &storage.engine.mysql.state.connection;
    // What a proxy handing the next message to a fresh server connection
    // looks like: the session the last message left is gone.
    try conn.query("SET SESSION sql_mode='',SESSION group_concat_max_len=4");
    while (!conn.isReady()) switch (try conn.next()) {
        .ok => {},
        else => return error.TestUnexpectedResult,
    };
    try conn.query("SELECT @@session.group_concat_max_len,INSTR(@@session.sql_mode,'NO_BACKSLASH_ESCAPES')>0");
    const Row = struct { len: u64, escapes_off: u64 };
    var columns: rows.Columns(Row) = undefined;
    var got: ?Row = null;
    while (!conn.isReady()) switch (try conn.next()) {
        .columns => |n| columns = try rows.readColumns(Row, conn, n),
        .row => {
            var row: Row = undefined;
            try rows.decodeRow(Row, &columns, conn, &row);
            got = row;
        },
        .rows_end => {},
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(got.?.len > 4);
    try std.testing.expectEqual(@as(u64, 1), got.?.escapes_off);
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
    try std.testing.expect(!storage.isFenced());
}

const Drop = @TypeOf(@as(@import("engine/Mysql.zig").State, undefined).testing_drop);

/// Commits one content row in a write Access whose COMMIT loses its
/// connection at `drop`, and returns the row's id with the commit's result.
fn commitLosing(storage: *Store, drop: Drop) !struct { id: u64, result: anyerror!void } {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
    defer access.deinit();
    errdefer access.abandon(.{}) catch {};
    const id = try access.identity(.content_id);
    access.write(live_insert, .{ .id = id, .digest = protocol.contentDigest("lost commit"), .length = 0 });
    storage.engine.mysql.state.testing_drop = drop;
    access.commit() catch |err| {
        access.abandon(.{}) catch {};
        return .{ .id = id, .result = err };
    };
    return .{ .id = id, .result = {} };
}

test "store.mysql live a connection lost around COMMIT reconnects and reports what landed" {
    for ([_]Drop{ .before_commit, .after_commit }) |drop| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try openLive(&storage, &tmp);
        defer storage.close() catch {};
        const state = storage.engine.mysql.state;
        const old_connection = state.connection_id;
        const got = try commitLosing(&storage, drop);
        const rows_saved = try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{got.id});
        switch (drop) {
            // COMMIT never left: nothing landed, and that is known.
            .before_commit => {
                try std.testing.expectError(error.StoreConnectionLost, got.result);
                try std.testing.expectEqual(@as(u64, 0), rows_saved);
            },
            // The server committed and only its OK was lost: success.
            .after_commit => {
                try got.result;
                try std.testing.expectEqual(@as(u64, 1), rows_saved);
            },
            .none, .next_pass => unreachable,
        }
        try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
        try std.testing.expect(state.connection_id != old_connection);
        // The new connection holds the lock: a second Store is refused.
        var second: Store = undefined;
        try std.testing.expectError(error.StoreLocked, open(&second, &tmp, std.testing.io, .{}));
        if (drop == .after_commit) {
            // The Store carries on writing on its new connection.
            try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
            try std.testing.expect(!storage.isFenced());
        }
    }
}

test "store.mysql live a reconnect onto a server admission refuses does not resume" {
    if (!try available()) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch {};
    // What a failover onto a weaker server looks like to the reconnect.
    const old = old: {
        mutex.lockUncancelable(std.testing.io);
        defer mutex.unlock(std.testing.io);
        _ = try connection();
        const old = try globalValue("innodb_flush_log_at_trx_commit");
        try setGlobal("innodb_flush_log_at_trx_commit", "2");
        break :old old;
    };
    defer {
        mutex.lockUncancelable(std.testing.io);
        defer mutex.unlock(std.testing.io);
        setGlobal("innodb_flush_log_at_trx_commit", old.slice()) catch @panic("cannot restore innodb_flush_log_at_trx_commit");
    }
    const got = try commitLosing(&storage, .after_commit);
    // Its counters are not trusted, so the outcome stays unknown, and no
    // write follows on that server.
    try std.testing.expectError(error.CommitOutcomeUnknown, got.result);
    try std.testing.expectEqual(@as(u64, 0), storage.engine.mysql.state.testing_shape.reconnects);
}

test "store.mysql live a reconnect never ends a session that does not hold the Store's lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch {};
    // Another Store's session under the same login, which KILL could end.
    var other_tmp = std.testing.tmpDir(.{});
    defer other_tmp.cleanup();
    var other: Store = undefined;
    try openLive(&other, &other_tmp);
    defer other.close() catch {};
    // What a restarted server that gave the old id to another client looks
    // like: the saved id names that session.
    storage.engine.mysql.state.connection_id = other.engine.mysql.state.connection_id;
    const got = try commitLosing(&storage, .after_commit);
    // The other session survives and keeps writing.
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&other, live_noop, .{}));
    try std.testing.expect(!other.isFenced());
    // Whether the lost session's lock had gone yet decides between resuming
    // and leaving the outcome unknown; either way the answer is true.
    const rows_saved = try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{got.id});
    if (got.result) |_| {
        try std.testing.expectEqual(@as(u64, 1), rows_saved);
    } else |err| try std.testing.expectEqual(error.CommitOutcomeUnknown, err);
}

const live_count = rsql.Read(.{
    .sql = "SELECT count(*) AS n FROM content WHERE content_id=?1",
    .Args = struct { id: u64 },
    .Row = struct { n: u64 },
    .cardinality = .one,
});

/// Queues COMMIT, then a count of `id`'s rows after it, and sends both.
fn commitThenCount(storage: *Store, id: u64) !u64 {
    const mysql = &storage.engine.mysql;
    try mysql.queueCommit();
    try mysql.bind(live_count, &.{ .id = id }, 0);
    try mysql.startPass();
    return countAfterCommit(storage);
}

fn countAfterCommit(storage: *Store) !u64 {
    const mysql = &storage.engine.mysql;
    if (!try mysql.nextRow()) return error.TestUnexpectedResult;
    var row: live_count.Row = undefined;
    try mysql.decodeRow(live_count.Row, &row);
    mysql.endStatement();
    try mysql.finishPass();
    return row.n;
}

test "store.mysql live a COMMIT and the reads after it share one message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const mysql = &storage.engine.mysql;
    const state = mysql.state;
    try mysql.control(.begin);
    _ = try liveWrite(&storage, live_insert, .{ .id = 9000400, .digest = protocol.contentDigest("commit-then-read") });
    const seq = state.commit_seq;
    const queries = state.connection.queries;
    // The read runs after COMMIT, so it sees the saved row.
    try std.testing.expectEqual(@as(u64, 1), try commitThenCount(&storage, 9000400));
    try std.testing.expectEqual(queries + 1, state.connection.queries);
    try std.testing.expectEqual(seq + 1, state.commit_seq);
    try std.testing.expect(!mysql.inTransaction());
    try std.testing.expectEqual(state.commit_seq, try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
    // The next transaction fences on the new counter.
    try mysql.control(.begin);
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
    try mysql.control(.commit);
    try std.testing.expectEqual(seq + 2, state.commit_seq);
    try std.testing.expect(!storage.isFenced());
}

test "store.mysql live a connection lost after COMMIT's OK keeps the commit and never runs it again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch {};
    const mysql = &storage.engine.mysql;
    const state = mysql.state;
    // As in a Queue batch, which may run again after a loss.
    state.armed = true;
    try mysql.control(.begin);
    _ = try liveWrite(&storage, live_insert, .{ .id = 9000410, .digest = protocol.contentDigest("lost-after-commit") });
    const seq = state.commit_seq;
    try mysql.queueCommit();
    try mysql.bind(live_count, &.{ .id = 9000410 }, 0);
    try mysql.startPass();
    // COMMIT's OK has arrived; the read's rows have not.
    try std.testing.expectEqual(seq + 1, state.commit_seq);
    state.connection.disconnect();
    try std.testing.expectError(error.StoreConnectionLost, countAfterCommit(&storage));
    try std.testing.expect(!mysql.defersFence());
    try std.testing.expect(!mysql.recover());
    try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{@as(u64, 9000410)}));
    try std.testing.expectEqual(seq + 1, try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
}

test "store.mysql live a COMMIT lost with reads after it answers them once it landed, and saves nothing otherwise" {
    const Case = struct { drop: Drop, armed: bool };
    for ([_]Case{
        .{ .drop = .before_commit, .armed = false },
        .{ .drop = .before_commit, .armed = true },
        .{ .drop = .after_commit, .armed = false },
        .{ .drop = .after_commit, .armed = true },
    }, 0..) |case, index| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try openLive(&storage, &tmp);
        defer storage.close() catch {};
        const mysql = &storage.engine.mysql;
        const state = mysql.state;
        const id: u64 = 9000420 + index;
        state.armed = case.armed;
        try mysql.control(.begin);
        _ = try liveWrite(&storage, live_insert, .{ .id = id, .digest = protocol.contentDigest("lost with reads") });
        const seq = state.commit_seq;
        state.testing_drop = case.drop;
        const got = commitThenCount(&storage, id);
        try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
        switch (case.drop) {
            // COMMIT never left: nothing landed, and the reads fail with it.
            .before_commit => {
                try std.testing.expectError(error.StoreConnectionLost, got);
                try std.testing.expectEqual(seq, state.commit_seq);
                try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{id}));
                // Only an armed batch runs again, and then it saves once.
                try std.testing.expectEqual(case.armed, mysql.defersFence());
                try std.testing.expectEqual(case.armed, mysql.recover());
                if (!case.armed) continue;
                try mysql.control(.begin);
                _ = try liveWrite(&storage, live_insert, .{ .id = id, .digest = protocol.contentDigest("lost with reads") });
                try std.testing.expectEqual(@as(u64, 1), try commitThenCount(&storage, id));
            },
            // The server committed and only the answers were lost: the
            // reads run again on the new connection, the writes never.
            .after_commit => {
                try std.testing.expectEqual(@as(u64, 1), try got);
                try std.testing.expect(!mysql.defersFence());
                try std.testing.expect(!mysql.recover());
            },
            .none, .next_pass => unreachable,
        }
        try std.testing.expectEqual(seq + 1, state.commit_seq);
        try std.testing.expectEqual(seq + 1, try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
        try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{id}));
        try std.testing.expect(!mysql.inTransaction());
        // The Store carries on writing on its new connection.
        try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
        try std.testing.expect(!storage.isFenced());
    }
}

/// A queued write of one content row, as an entry point runs one.
fn insertHeld(storage: *Store, id: u64) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
    defer access.deinit();
    access.write(live_insert, .{ .id = id, .digest = protocol.contentDigest(std.mem.asBytes(&id)), .length = 0 });
    return entry.finishTransaction(store_core.Ordinary.none, .{}, access.end(.{}, access.commit()));
}

test "store.mysql live a write whose connection was lost with nothing saved runs again, unseen" {
    for ([_]Drop{ .next_pass, .before_commit }) |drop| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try openLive(&storage, &tmp);
        defer storage.close() catch {};
        const state = storage.engine.mysql.state;
        const id: u64 = 9000100;
        state.testing_drop = drop;
        // The caller hears success: the loss and the rerun stay inside.
        try storage.queue().write(insertHeld, .{ &storage, id });
        try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
        try std.testing.expect(!storage.isFenced());
        try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{id}));
        // The Store keeps writing on its new connection.
        try storage.queue().write(insertHeld, .{ &storage, id + 1 });
        try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
    }
}

/// A queued write of one content row and a touch of another's, as an
/// entry point runs them.
fn insertTouching(storage: *Store, id: u64, other: u64) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
    defer access.deinit();
    access.write(live_insert, .{ .id = id, .digest = protocol.contentDigest(std.mem.asBytes(&id)), .length = 0 });
    access.write(live_touch, .{ .id = other });
    return entry.finishTransaction(error{LiveGuard}, .{}, access.end(.{}, access.commit()));
}

test "store.mysql live a lone write sends its transaction, its writes and its COMMIT as one message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const state = storage.engine.mysql.state;
    var before = state.connection.queries;
    try storage.queue().write(insertTouching, .{ &storage, 9000400, 9000400 });
    try std.testing.expectEqual(before + 1, state.connection.queries);
    try std.testing.expect(!storage.engine.mysql.inTransaction());
    try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000400", .{}));
    // A write that changes the wrong number of rows stops the message
    // before its COMMIT: the server saves nothing of it.
    const seq = state.commit_seq;
    before = state.connection.queries;
    try std.testing.expectError(error.LiveGuard, storage.queue().write(insertTouching, .{ &storage, 9000401, 9000499 }));
    // The message, then ROLLBACK.
    try std.testing.expectEqual(before + 2, state.connection.queries);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(seq, state.commit_seq);
    try std.testing.expectEqual(seq, try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000401", .{}));
    // The Store carries on.
    try storage.queue().write(insertTouching, .{ &storage, 9000402, 9000400 });
    try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000402", .{}));
}

/// `insertTouching`, with the insert sent before the touch is bound, and
/// the touch bound into a batch with `room` bytes.
fn insertThenTouch(storage: *Store, id: u64, other: u64, room: usize) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
    defer access.deinit();
    access.write(live_insert, .{ .id = id, .digest = protocol.contentDigest(std.mem.asBytes(&id)), .length = 0 });
    var count: live_count.Result = undefined;
    access.read(live_count, .{ .id = id }, &count);
    try entry.finishTransaction(error{LiveGuard}, .{}, access.end(.{}, access.run()));
    const wire_connection = &storage.engine.mysql.state.connection;
    const limit = wire_connection.batch_limit;
    defer wire_connection.batch_limit = limit;
    wire_connection.batch_limit = limit - (wire_connection.batchRoom() - room);
    access.write(live_touch, .{ .id = other });
    return entry.finishTransaction(error{LiveGuard}, .{}, access.end(.{}, access.commit()));
}

test "store.mysql live a write the batch cannot guard never shares its message with COMMIT" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    // The touch is 59 bytes: from a batch too small for it, which sends it
    // alone, through one with room for it and no guard, to one that holds
    // both.
    var room: usize = 40;
    var id: u64 = 9000700;
    while (room <= 280) : (room += 24) {
        // A wrong count saves nothing, wherever COMMIT would have gone.
        try std.testing.expectError(error.LiveGuard, storage.queue().write(insertThenTouch, .{ &storage, id, 9000799, room }));
        try std.testing.expect(!storage.isFenced());
        try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{id}));
        // A right one saves.
        try storage.queue().write(insertThenTouch, .{ &storage, id, id, room });
        try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{id}));
        id += 1;
    }
}

test "store.mysql live a lone write saved with every answer lost still counts as a change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const state = storage.engine.mysql.state;
    const generation = storage.commitGeneration();
    // The server runs the transaction's one message whole; the connection
    // is lost before its first answer.
    state.testing_drop = .after_commit;
    try storage.queue().write(insertHeld, .{ &storage, 9000600 });
    try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000600", .{}));
    try std.testing.expectEqual(generation + 1, storage.commitGeneration());
    // Lost before it was sent, the write runs again and counts once.
    state.testing_drop = .before_commit;
    try storage.queue().write(insertHeld, .{ &storage, 9000601 });
    try std.testing.expectEqual(@as(u64, 2), state.testing_shape.reconnects);
    try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000601", .{}));
    try std.testing.expectEqual(generation + 2, storage.commitGeneration());
}

test "store.mysql live a lone write's message carries the dispatch survey the Host asks for next" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const queries = &storage.engine.mysql.state.connection.queries;
    // Until the Host asks, a commit carries nothing.
    var before = queries.*;
    try storage.queue().write(insertHeld, .{ &storage, 9000800 });
    try std.testing.expectEqual(before + 1, queries.*);
    const asked = try storage.dispatchWork(false);
    try std.testing.expectEqual(before + 2, queries.*);
    // Then a commit's one message carries the survey, and the next ask
    // sends nothing and answers as a survey of its own does.
    before = queries.*;
    try storage.queue().write(insertHeld, .{ &storage, 9000801 });
    try std.testing.expectEqual(before + 1, queries.*);
    const carried = try storage.dispatchWork(false);
    try std.testing.expectEqual(before + 1, queries.*);
    try std.testing.expectEqual(asked, carried);
    // It answers one ask.
    try std.testing.expectEqual(carried, try storage.dispatchWork(false));
    try std.testing.expectEqual(before + 2, queries.*);
    // An ask with Turns held is another survey.
    before = queries.*;
    try storage.queue().write(insertHeld, .{ &storage, 9000802 });
    _ = try storage.dispatchWork(true);
    try std.testing.expectEqual(before + 2, queries.*);
    // A write that saved nothing leaves no survey: the message, ROLLBACK,
    // then the Host's own.
    before = queries.*;
    try std.testing.expectError(error.LiveGuard, storage.queue().write(insertTouching, .{ &storage, 9000803, 9000899 }));
    _ = try storage.dispatchWork(true);
    try std.testing.expectEqual(before + 3, queries.*);
    try std.testing.expect(!storage.isFenced());
    // A carried survey is dropped by a later commit that carries none:
    // two writes sharing a batch.
    _ = try storage.dispatchWork(false);
    try storage.queue().write(insertHeld, .{ &storage, 9000804 });
    const Writer = struct {
        result: anyerror!void = {},
        fn hold() error{}!void {}
        fn write(self: *@This(), s: *Store, id: u64) void {
            self.result = s.queue().write(insertHeld, .{ s, id });
        }
    };
    try storage.queue().callHeld(Writer.hold, .{});
    var writers: [2]Writer = .{ .{}, .{} };
    var threads: [2]std.Thread = undefined;
    for (&threads, &writers, 0..) |*thread, *writer, index| {
        thread.* = try std.Thread.spawn(.{}, Writer.write, .{ writer, &storage, 9000805 + index });
        @import("queue.zig").waitQueued(storage.queue(), index + 1);
    }
    storage.queue().release();
    for (threads) |thread| thread.join();
    for (writers) |writer| try writer.result;
    before = queries.*;
    _ = try storage.dispatchWork(false);
    try std.testing.expectEqual(before + 1, queries.*);
}

/// `insertHeld`, committing into a batch with `room` bytes left after the
/// insert.
fn insertWithRoom(storage: *Store, id: u64, room: usize) !void {
    const entry = try store_core.enter(storage, .none);
    defer entry.release();
    var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
    defer access.deinit();
    access.write(live_insert, .{ .id = id, .digest = protocol.contentDigest(std.mem.asBytes(&id)), .length = 0 });
    const wire_connection = &storage.engine.mysql.state.connection;
    const limit = wire_connection.batch_limit;
    defer wire_connection.batch_limit = limit;
    wire_connection.batch_limit = limit - (wire_connection.batchRoom() - room);
    return entry.finishTransaction(store_core.Ordinary.none, .{}, access.end(.{}, access.commit()));
}

test "store.mysql live a write saves in its one message whether or not the batch has room for the survey" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const queries = &storage.engine.mysql.state.connection.queries;
    _ = try storage.dispatchWork(false);
    // From room for COMMIT and none of the survey, through part of it, to
    // all of it: the write is one message and saves, and the Host's ask
    // is free only when the whole survey rode.
    var id: u64 = 9000900;
    var carried: [2]bool = .{ false, false };
    var room: usize = 32;
    while (room <= 32768) : (room *= 2) {
        const before = queries.*;
        try storage.queue().write(insertWithRoom, .{ &storage, id, room });
        try std.testing.expectEqual(before + 1, queries.*);
        try std.testing.expect(!storage.isFenced());
        _ = try storage.dispatchWork(false);
        const asked = queries.* - before - 1;
        try std.testing.expect(asked <= 1);
        carried[@intFromBool(asked == 0)] = true;
        // Once the whole survey fits, more room changes nothing.
        if (asked == 1) try std.testing.expect(!carried[1]);
        try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=?1", .{id}));
        id += 1;
    }
    try std.testing.expect(carried[0] and carried[1]);
}

test "store.mysql live a carried survey whose read fails fences as the Host's own does, and the write stands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch |err| {
        std.testing.expectEqual(error.StoreCloseFailed, err) catch unreachable;
    };
    _ = try storage.dispatchWork(false);
    const generation = storage.commitGeneration();
    // A table the survey reads is gone: its SELECT fails after COMMIT ran.
    try rawExec(&storage, "RENAME TABLE session_stop_owed TO session_stop_owed_gone");
    try storage.queue().write(insertHeld, .{ &storage, 9000950 });
    try std.testing.expect(storage.isFenced());
    try std.testing.expectEqual(generation + 1, storage.commitGeneration());
    try rawExec(&storage, "RENAME TABLE session_stop_owed_gone TO session_stop_owed");
    try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000950", .{}));
}

test "store.mysql live a lone write whose fence fails saves nothing, though COMMIT shares its message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch |err| {
        std.testing.expectEqual(error.StoreCloseFailed, err) catch unreachable;
    };
    // Another owner's commit, while this connection still holds GET_LOCK.
    try exec(&storage, "UPDATE store_owner SET commit_seq=commit_seq+1 WHERE owner_key=1", .{});
    if (storage.queue().write(insertHeld, .{ &storage, 9000500 })) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expect(storage.isFenced());
    try std.testing.expectEqual(error.OwnershipLost, storage.engine.mysql.state.failure.?);
    try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000500", .{}));
}

test "store.mysql live a batch that loses its connection mid-pass runs every write again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch {};
    const state = storage.engine.mysql.state;
    const Writer = struct {
        result: anyerror!void = {},
        fn hold() error{}!void {}
        fn write(self: *@This(), s: *Store, id: u64) void {
            self.result = s.queue().write(insertHeld, .{ s, id });
        }
    };
    // Two writes queue behind a holder, so they run as one batch.
    try storage.queue().callHeld(Writer.hold, .{});
    var writers: [2]Writer = .{ .{}, .{} };
    var threads: [2]std.Thread = undefined;
    for (&threads, &writers, 0..) |*thread, *writer, index| {
        thread.* = try std.Thread.spawn(.{}, Writer.write, .{ writer, &storage, 9000300 + index });
        @import("queue.zig").waitQueued(storage.queue(), index + 1);
    }
    // The first write's statements lose the connection; the second must
    // not run on the lost batch, and both run again on the new one.
    state.testing_drop = .next_pass;
    storage.queue().release();
    for (threads) |thread| thread.join();
    for (writers) |writer| try writer.result;
    try std.testing.expectEqual(@as(u64, 1), state.testing_shape.reconnects);
    try std.testing.expect(!storage.isFenced());
    try std.testing.expectEqual(@as(u64, 2), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id IN (9000300,9000301)", .{}));
}

test "store.mysql live a write that loses its connection twice fences" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch {};
    const state = storage.engine.mysql.state;
    // The first attempt loses its connection before COMMIT.
    state.testing_drop_armed = true;
    const Twice = struct {
        fn held(s: *Store, id: u64) !void {
            // The rerun loses its connection too.
            if (!s.engine.mysql.state.armed) s.engine.mysql.state.testing_drop = .next_pass;
            return insertHeld(s, id);
        }
    };
    // The writer keeps its own error, and the Store fences.
    if (storage.queue().write(Twice.held, .{ &storage, 9000200 })) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expect(storage.isFenced());
}

test "store.mysql live GET_LOCK excludes a second Store on the same database" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    var second: Store = undefined;
    try std.testing.expectError(error.StoreLocked, open(&second, &tmp, std.testing.io, .{}));
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
    try std.testing.expect(!storage.isFenced());
}

fn liveBackupFence(comptime column: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    // A root writer simulates a changed owner or a restored backup while
    // this connection still holds GET_LOCK. The first write must refuse.
    defer storage.close() catch |err| {
        std.testing.expectEqual(error.StoreCloseFailed, err) catch unreachable;
    };
    try exec(&storage, "UPDATE store_owner SET " ++ column ++ "=" ++ column ++ "+1 WHERE owner_key=1", .{});
    try storage.engine.mysql.control(.begin);
    try std.testing.expectError(error.OwnershipLost, liveWrite(&storage, live_noop, .{}));
    try std.testing.expectEqual(error.OwnershipLost, storage.engine.mysql.state.failure.?);
    try std.testing.expectError(error.OwnershipLost, storage.engine.mysql.check());
}

test "store.mysql live epoch backup fence works while GET_LOCK remains held" {
    try liveBackupFence("epoch");
}

test "store.mysql live commit sequence backup fence works while GET_LOCK remains held" {
    try liveBackupFence("commit_seq");
}

const live_touch = rsql.Write(.{
    .sql = "UPDATE content SET private=private WHERE content_id=?1",
    .Args = struct { id: u64 },
    .expect = .{ .exact = .{ .rows = 1, .otherwise = error.LiveGuard } },
});

test "store.mysql live deadlock victim keeps no sent transaction evidence for the next write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const a: u64 = 9000040;
    const b: u64 = 9000041;
    _ = try liveWrite(&storage, live_insert, .{ .id = a, .digest = protocol.contentDigest("deadlock-a") });
    _ = try liveWrite(&storage, live_insert, .{ .id = b, .digest = protocol.contentDigest("deadlock-b") });

    // A second login takes row a after 32 inserts, so InnoDB picks the
    // lighter Store transaction as the deadlock victim.
    const config = (try dialect.rootConfig()).?;
    const peer = try std.testing.allocator.create(wire.Connection);
    defer std.testing.allocator.destroy(peer);
    var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refusal.deinit();
    try peer.open(.{ .address = .{ .unix_socket = config.socket }, .user = "root", .password = config.password, .database = database(&storage) }, &refusal.writer);
    defer peer.close();
    try peer.query("START TRANSACTION;INSERT INTO content(content_id,digest,byte_length,private) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<32) SELECT 9000100+i,UNHEX(SHA2(i,256)),0,0 FROM n;UPDATE content SET private=private WHERE content_id=9000040");
    try drain(peer, null);
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
        defer access.deinit();
        access.write(live_touch, .{ .id = b });
        try access.run();
        // The peer waits on row b, then the Store waits on row a.
        try peer.query("UPDATE content SET private=private WHERE content_id=9000041");
        access.write(live_touch, .{ .id = a });
        try std.testing.expectError(error.StatementFailed, access.run());
        // Only a deadlock (1213) or lost savepoint (1305) ends it here.
        try std.testing.expect(!storage.engine.inTransaction());
        try access.abandon(.{});
    }
    try drain(peer, null);
    try peer.query("ROLLBACK");
    try drain(peer, null);

    // The server ended the victim's transaction, so the next write's
    // BEGIN is unsent until its pass. Abandoning it first contacts no one.
    const before = storage.engine.mysql.state.connection.queries;
    {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
        defer access.deinit();
        access.write(live_touch, .{ .id = a });
        try access.abandon(.{});
    }
    try std.testing.expectEqual(@as(u64, 0), storage.engine.mysql.state.connection.queries - before);
    try std.testing.expect(!storage.engine.inTransaction());
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
    try std.testing.expect(!storage.isFenced());
}

test "store.mysql live unchanged UPDATE reports observed latency rounds and fixed buffer sizes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    var elapsed: [5]i128 = undefined;
    const before = storage.engine.mysql.state.connection.queries;
    for (&elapsed) |*sample| {
        const start = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds;
        try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
        sample.* = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds - start;
    }
    const queries = storage.engine.mysql.state.connection.queries - before;
    try std.testing.expectEqual(@as(u64, elapsed.len), queries);
    std.mem.sort(i128, &elapsed, {}, std.sort.asc(i128));
    std.debug.print("MySQL CI observation (not A/B): unchanged UPDATE median {d} ns, range {d}..{d} ns, {d} samples, {d} COM_QUERY; State {d} bytes, Connection {d} bytes (included in State), receive buffer {d} bytes, batch text capacity {d} bytes; heap column kinds {d} bytes. No Private_Dirty/PSS/RSS sampling; excludes allocator/OpenSSL allocations.\n", .{
        elapsed[2],           elapsed[0],               elapsed[4],                    elapsed.len,      queries,
        @sizeOf(Mysql.State), @sizeOf(wire.Connection), wire.mysql.receive_buffer_min, wire.batch_bytes, storage.engine.mysql.state.kinds.len * @sizeOf(rows.Kind),
    });
}

const LinuxMemory = struct {
    private_dirty_kib: u64 = 0,
    anonymous_kib: u64 = 0,
    pss_kib: u64 = 0,
    rss_kib: u64 = 0,

    fn parse(text: []const u8) !LinuxMemory {
        var sample: LinuxMemory = .{};
        var seen: u8 = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            inline for (.{
                .{ "Private_Dirty", "private_dirty_kib" },
                .{ "Anonymous", "anonymous_kib" },
                .{ "Pss", "pss_kib" },
                .{ "Rss", "rss_kib" },
            }, 0..) |field, index| {
                if (std.mem.eql(u8, line[0..colon], field[0])) {
                    var words = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t\r");
                    const value = try std.fmt.parseInt(u64, words.next() orelse return error.InvalidSmapsRollup, 10);
                    if (!std.mem.eql(u8, words.next() orelse return error.InvalidSmapsRollup, "kB")) return error.InvalidSmapsRollup;
                    if (words.next() != null) return error.InvalidSmapsRollup;
                    @field(sample, field[1]) = value;
                    seen |= @as(u8, 1) << index;
                }
            }
        }
        if (seen != 15) return error.IncompleteSmapsRollup;
        return sample;
    }

    /// No allocation, trimming, advice or warmup before a sample. Linux's
    /// smaps `kB` values are binary KiB; retain them without relabelling.
    fn read() !LinuxMemory {
        const file = try std.Io.Dir.cwd().openFile(std.testing.io, "/proc/self/smaps_rollup", .{});
        defer file.close(std.testing.io);
        var buffer: [8192]u8 = undefined;
        var filled: usize = 0;
        while (filled < buffer.len) {
            const n = file.readStreaming(std.testing.io, &.{buffer[filled..]}) catch |err| switch (err) {
                error.EndOfStream => return parse(buffer[0..filled]),
                else => return err,
            };
            filled += n;
        }
        return error.SmapsRollupTooLarge;
    }

    fn print(sample: LinuxMemory, rep: usize, phase: []const u8) void {
        std.debug.print("MySQL native UNIT PROCESS memory rep={d} phase={s}: Private_Dirty={d} KiB Anonymous={d} KiB Pss={d} KiB Rss={d} KiB\n", .{
            rep, phase, sample.private_dirty_kib, sample.anonymous_kib, sample.pss_kib, sample.rss_kib,
        });
    }
};

const live_epoch = rsql.Read(.{
    .sql = "SELECT epoch FROM store_owner WHERE owner_key=1",
    .Args = struct {},
    .Row = struct { epoch: u64 },
    .cardinality = .one,
});

fn liveReadEpoch(storage: *Store) !u64 {
    const mysql = &storage.engine.mysql;
    try mysql.bind(live_epoch, &.{}, 0);
    try mysql.startPass();
    try std.testing.expect(try mysql.nextRow());
    var row: live_epoch.Row = undefined;
    try mysql.decodeRow(live_epoch.Row, &row);
    try std.testing.expect(!try mysql.nextRow());
    mysql.endStatement();
    try mysql.finishPass();
    return row.epoch;
}

test "store.mysql live Linux unit process idle and fixed workload private memory observations" {
    if (!os.proc_memory) return error.SkipZigTest;
    if (!try available()) return error.SkipZigTest;
    std.debug.print("MySQL memory evidence: 3 fresh Stores in this native UNIT PROCESS, not isolated Host/per-Store memory. Includes fixture/root/schema setup and unit-process allocator history. Unix socket only: TLS not measured. No trim/madvise, warmup, discarded repetitions or acceptance thresholds. Kernel kB reported as exact KiB; process tree not sampled.\n", .{});
    for (0..3) |rep| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const before = try LinuxMemory.read();
        var storage: Store = undefined;
        try openLive(&storage, &tmp);
        var closed = false;
        defer if (!closed) storage.close() catch unreachable;
        const idle = try LinuxMemory.read();
        const queries_before = storage.engine.mysql.state.connection.queries;
        const epoch = storage.engine.mysql.state.epoch;
        // Sixteen identical read/write pairs, no population growth or
        // content-sized allocations: the UPDATE matches without changing.
        for (0..16) |_| {
            try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
            try std.testing.expectEqual(epoch, try liveReadEpoch(&storage));
        }
        const queries = storage.engine.mysql.state.connection.queries - queries_before;
        try std.testing.expectEqual(@as(u64, 32), queries);
        try std.testing.expect(!storage.isFenced());
        const after_work = try LinuxMemory.read();
        closed = true;
        try storage.close();
        const after_close = try LinuxMemory.read();
        // Print only after all four samples, so diagnostics themselves do
        // not selectively precede one phase's memory observation.
        before.print(rep + 1, "before-open");
        idle.print(rep + 1, "idle-after-open");
        after_work.print(rep + 1, "after-16-fixed-read-write-pairs");
        after_close.print(rep + 1, "after-close");
        const dirty_delta = @as(i128, after_work.private_dirty_kib) - @as(i128, idle.private_dirty_kib);
        std.debug.print("MySQL native UNIT PROCESS rep={d}: workload COM_QUERY={d}, postwork-minus-idle Private_Dirty={d} KiB; amortized {d} bytes/query is arithmetic only, not measured per-call allocation or a Host memory claim.\n", .{
            rep + 1, queries, dirty_delta, @divTrunc(dirty_delta * 1024, queries),
        });
    }
}

test "store.mysql Linux memory observation reads proc without a database" {
    if (!os.proc_memory) return error.SkipZigTest;
    const sample = try LinuxMemory.read();
    try std.testing.expect(sample.rss_kib > 0);
}

test "Linux memory observation parses all four exact KiB counters" {
    const sample = try LinuxMemory.parse("0000-ffff [rollup]\nRss: 31 kB\nPss: 23 kB\nPrivate_Dirty: 17 kB\nAnonymous: 11 kB\nOther: 7 kB\n");
    try std.testing.expectEqual(@as(u64, 17), sample.private_dirty_kib);
    try std.testing.expectEqual(@as(u64, 11), sample.anonymous_kib);
    try std.testing.expectEqual(@as(u64, 23), sample.pss_kib);
    try std.testing.expectEqual(@as(u64, 31), sample.rss_kib);
    try std.testing.expectError(error.IncompleteSmapsRollup, LinuxMemory.parse("Private_Dirty: 17 kB\n"));
    try std.testing.expectError(error.InvalidSmapsRollup, LinuxMemory.parse("Private_Dirty: 17 MB\n"));
}

test "store.mysql live buffered payloads keep streamed query budgets under queue and packet pressure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const chunk = schema.content_chunk_bytes;
    const bytes = try std.testing.allocator.alloc(u8, 9 * chunk + 17);
    defer std.testing.allocator.free(bytes);
    // Reused source, never mutated until both kinds of queued borrow end.
    for ([_]usize{ 0, 1, chunk - 1, chunk, chunk + 1, 3 * chunk + 17, bytes.len }) |length| {
        for ([_]bool{ false, true }) |buffered| {
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
            defer access.deinit();
            errdefer access.abandon(.{}) catch {};
            @memset(bytes, if (buffered) 'b' else 's');
            // Distinct fixture keys even for empty content and catalog rows.
            var key: [64]u8 = undefined;
            const digest = protocol.contentDigest(try std.fmt.bufPrint(&key, "budget-{d}-{any}", .{ length, buffered }));
            const id = try access.identity(.content_id);
            const before = storage.engine.mysql.state.connection.queries;
            access.write(live_insert, .{ .id = id, .digest = digest, .length = length });
            if (buffered) {
                access.writeContent(id, bytes[0..length]);
            } else {
                access.recordContentRow(id);
                const sink = try access.contentSink(id, length);
                defer sink.close();
                try sink.write(bytes[0..length], 0);
            }
            // A row write after the bytes shares the last data pass.
            access.write(live_noop, .{});
            try access.commit();
            const queries: u64 = if (length > 8 * chunk) 3 else 2;
            try std.testing.expectEqual(before + queries, storage.engine.mysql.state.connection.queries);
            const chunks: u64 = @intCast((length + chunk - 1) / chunk);
            try std.testing.expectEqual(chunks, try queryU64(&storage, "SELECT count(*) FROM content_chunk WHERE content_id=?1", .{id}));
        }
    }
    // Bound the outgoing batch below two chunks without changing the
    // on-disk layout: one pass per chunk here, never a larger packet.
    const connection_state = &storage.engine.mysql.state.connection;
    const limit = connection_state.batch_limit;
    defer connection_state.batch_limit = limit;
    // Leave room for the opening fence's server-side guard and the row
    // alongside the first chunk, while still refusing two full chunks.
    connection_state.batch_limit = 2 * chunk + 2048;
    for ([_]bool{ false, true }) |buffered| {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
        defer access.deinit();
        errdefer access.abandon(.{}) catch {};
        const id = try access.identity(.content_id);
        const before = connection_state.queries;
        access.write(live_insert, .{ .id = id, .digest = protocol.contentDigest(if (buffered) "packet-buffered" else "packet-streamed"), .length = 2 * chunk });
        if (buffered) {
            access.writeContent(id, bytes[0 .. 2 * chunk]);
        } else {
            access.recordContentRow(id);
            const sink = try access.contentSink(id, 2 * chunk);
            defer sink.close();
            try sink.write(bytes[0 .. 2 * chunk], 0);
        }
        try access.commit();
        try std.testing.expectEqual(before + 3, connection_state.queries);
    }
}

const single_owner = rsql.Read(.{
    .sql = "SELECT commit_seq FROM store_owner WHERE owner_key=1",
    .Args = struct {},
    .Row = struct { commit_seq: u64 },
    .cardinality = .one,
});

/// A single-commit transition for the live tests: reads the owner row
/// when asked, outside any round or in one, queues `write`, steps it in a
/// round of its own when asked, then commits or ends `.done`.
const LiveSingle = struct {
    pub const rounds = transition.rounds(.{ .read = .{.branch}, .write = .{.branch} });
    pub const round_budget = 1;
    pub const commit: transition.Commit = .single;
    pub const begin: ?rounds.At = .read;
    pub const Input = struct {
        storage: *Store,
        read: enum { none, queued, run } = .none,
        write: union(enum) { none, insert: struct { id: u64, text: []const u8 }, guard, touch: u64 } = .none,
        step_write: bool = false,
        finish: enum { commit, done } = .commit,
    };
    pub const Result = void;
    pub const Ordinary = error{LiveGuard};
    pub const Guards = error{LiveGuard};
    pub const Declined = error{};

    input: Input,
    row: single_owner.Result = undefined,
    /// Whether a transaction was open once the read round ran, and once
    /// the write was queued.
    read_open: bool = false,
    queued_open: bool = false,

    pub fn step(t: *LiveSingle, r: *transition.Round(LiveSingle), ran: ?rounds.At) !transition.Next(LiveSingle) {
        if (ran == null) {
            if (t.input.read != .none) r.read(single_owner, .{}, &t.row);
            if (t.input.read == .run) return .{ .round = .read };
        }
        if (ran == null or ran.? == .read) {
            if (ran != null) t.read_open = t.input.storage.engine.inTransaction();
            switch (t.input.write) {
                .none => {},
                .insert => |row| r.write(live_insert, .{ .id = row.id, .digest = protocol.contentDigest(row.text) }),
                .guard => r.write(live_guard, .{}),
                .touch => |id| r.write(live_touch, .{ .id = id }),
            }
            t.queued_open = t.input.storage.engine.inTransaction();
            if (t.input.step_write) return .{ .round = .write };
        }
        return switch (t.input.finish) {
            .commit => .commit,
            .done => .{ .done = {} },
        };
    }

    pub fn committed(_: *const LiveSingle) Result {}
};

test "store.mysql live single commit writes one fenced domain write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const seq = try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{});
    const entry = try store_core.enter(&storage, .none);
    defer entry.release();
    var single: LiveSingle = .{ .input = .{ .storage = &storage, .write = .{ .insert = .{ .id = 9000400, .text = "single-success" } } } };
    const before = storage.engine.mysql.state.connection.queries;
    try entry.finishTransaction(error{LiveGuard}, .{}, transition.run(&entry, LiveSingle, &single, .{}));
    // Single is semantic intent, not permission to bypass the fence.
    try std.testing.expect(single.queued_open);
    try std.testing.expectEqual(before + 2, storage.engine.mysql.state.connection.queries);
    try std.testing.expect(!storage.engine.inTransaction());
    try std.testing.expectEqual(seq + 1, try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
    try std.testing.expectEqual(@as(u64, 1), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000400", .{}));
    try std.testing.expect(!storage.isFenced());
}

test "store.mysql live single commit's done closes every opening state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const seq = try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{});
    for ([_]enum { lazy, pending, read, queued, stepped }{ .lazy, .pending, .read, .queued, .stepped }) |state| {
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var single: LiveSingle = .{ .input = .{
            .storage = &storage,
            .read = switch (state) {
                .lazy => .none,
                .pending => .queued,
                .read, .queued, .stepped => .run,
            },
            .write = if (state == .queued or state == .stepped) .{ .insert = .{ .id = 9000401, .text = "single-abandoned" } } else .none,
            .step_write = state == .stepped,
            .finish = .done,
        } };
        try entry.finishTransaction(error{LiveGuard}, .{}, transition.run(&entry, LiveSingle, &single, .{}));
        if (state == .read or state == .queued or state == .stepped) {
            try std.testing.expect(single.read_open);
            try std.testing.expectEqual(seq + 1, single.row.commit_seq);
        }
        try std.testing.expect(!storage.engine.inTransaction());
        try std.testing.expect(storage.engine.mysql.state.connection.isReady());
        try std.testing.expectEqual(seq, try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
        try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000401", .{}));
        try std.testing.expect(!storage.isFenced());
    }
}

test "store.mysql live single commit guard failure rolls back and rollback failure fences at Entry" {
    for ([_]bool{ false, true }) |rollback_fails| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try openLive(&storage, &tmp);
        defer storage.close() catch unreachable;
        const seq = try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{});
        {
            const entry = try store_core.enter(&storage, .none);
            defer entry.release();
            const faults: store_core.Faults = .{ .rollback_failure = rollback_fails };
            var single: LiveSingle = .{ .input = .{ .storage = &storage, .write = .guard } };
            const result = entry.finishTransaction(error{LiveGuard}, faults, transition.run(&entry, LiveSingle, &single, faults));
            if (rollback_fails) {
                try std.testing.expectError(error.CanonicalRollbackFailed, result);
                try std.testing.expect(storage.isFenced());
                // The unresolved transaction stays owned until close.
                try std.testing.expect(storage.engine.inTransaction());
            } else {
                try std.testing.expectError(error.LiveGuard, result);
                try std.testing.expect(!storage.isFenced());
                try std.testing.expect(!storage.engine.inTransaction());
                try std.testing.expectEqual(seq, try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
            }
        }
    }
}

test "store.mysql live single commit ownership loss refuses its write and fences at Entry" {
    inline for (.{ "epoch", "commit_seq" }) |column| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: Store = undefined;
        try openLive(&storage, &tmp);
        defer storage.close() catch |err| {
            std.testing.expectEqual(error.StoreCloseFailed, err) catch unreachable;
        };
        try exec(&storage, "UPDATE store_owner SET " ++ column ++ "=" ++ column ++ "+1 WHERE owner_key=1", .{});
        const entry = try store_core.enter(&storage, .none);
        defer entry.release();
        var single: LiveSingle = .{ .input = .{ .storage = &storage, .write = .{ .insert = .{ .id = 9000402, .text = "single-lost-owner" } } } };
        // The commit's OwnershipLost cannot be rolled back with ownership
        // confirmed either, so the failed rollback takes its place at the
        // same boundary used by ordinary writes; the engine keeps the cause.
        const result = entry.finishTransaction(error{LiveGuard}, .{}, transition.run(&entry, LiveSingle, &single, .{}));
        try std.testing.expectError(error.CanonicalRollbackFailed, result);
        try std.testing.expectEqual(@as(?@import("engine.zig").Failure, error.OwnershipLost), storage.engine.mysql.state.failure);
        try std.testing.expect(storage.isFenced());
        try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000402", .{}));
    }
}

fn singleTouchHeld(storage: *Store, id: u64) !void {
    return transition.apply(storage, LiveSingle, .{ .storage = storage, .write = .{ .touch = id } }, .{});
}

test "store.mysql live lone single writes guard their shared COMMIT and payload lowering keeps it batched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    var needs_close = true;
    // Keep an owner assertion primary if a negative control fences the
    // connection; successful execution still checks close below.
    defer if (needs_close) storage.close() catch {};
    const state = storage.engine.mysql.state;
    _ = try liveWrite(&storage, live_insert, .{ .id = 9000800, .digest = protocol.contentDigest("single-inline-commit") });
    var before = state.connection.queries;
    try storage.queue().write(singleTouchHeld, .{ &storage, 9000800 });
    try std.testing.expectEqual(before + 1, state.connection.queries);
    const seq = state.commit_seq;
    before = state.connection.queries;
    try std.testing.expectError(error.LiveGuard, storage.queue().write(singleTouchHeld, .{ &storage, 9000899 }));
    try std.testing.expectEqual(before + 2, state.connection.queries);
    try std.testing.expectEqual(seq, try queryU64(&storage, "SELECT commit_seq FROM store_owner WHERE owner_key=1", .{}));
    try std.testing.expect(!storage.isFenced());
    try std.testing.expect(!storage.engine.inTransaction());

    const Payload = struct {
        fn write(s: *Store, bytes: []const u8, buffered: bool) !void {
            const entry = try store_core.enter(s, .none);
            defer entry.release();
            var access: store_access.Access(.write, error{LiveGuard}) = .open(&entry);
            defer access.deinit();
            errdefer access.abandon(.{}) catch {};
            const id = try access.identity(.content_id);
            access.write(live_insert, .{ .id = id, .digest = protocol.contentDigest(std.mem.asBytes(&id)), .length = bytes.len });
            if (buffered) {
                access.writeContent(id, bytes);
            } else {
                access.recordContentRow(id);
                const sink = try access.contentSink(id, bytes.len);
                defer sink.close();
                try sink.write(bytes, 0);
            }
            access.write(live_touch, .{ .id = id });
            return entry.finishTransaction(error{LiveGuard}, .{}, access.end(.{}, access.commit()));
        }
    };
    const bytes = try std.testing.allocator.alloc(u8, schema.content_chunk_bytes + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'p');
    // Reload after the explicit fixture row, then let each Access take
    // the next id exactly as a production import does.
    try store_core.reloadIdentitiesForTesting(&storage);
    for ([_]bool{ false, true }) |buffered| {
        before = state.connection.queries;
        try storage.queue().write(Payload.write, .{ &storage, bytes, buffered });
        try std.testing.expectEqual(before + 1, state.connection.queries);
        try std.testing.expect(!storage.engine.inTransaction());
    }
    needs_close = false;
    try storage.close();
}
