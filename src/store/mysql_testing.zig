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

test "store.mysql live admission refuses read_only" {
    try refusesGlobal("read_only", "1", error.MysqlReadOnly);
}

test "store.mysql live admission refuses super_read_only" {
    try refusesGlobal("super_read_only", "1", error.MysqlReadOnly);
}

test "store.mysql live admission refuses weak InnoDB commit flush" {
    try refusesGlobal("innodb_flush_log_at_trx_commit", "2", error.MysqlDurabilityTooWeak);
}

test "store.mysql live admission refuses weak binlog sync" {
    // CI starts with log_bin enabled. log_bin itself is not dynamic, and
    // the pure refusal test covers the disabled-binlog combinations.
    try refusesGlobal("sync_binlog", "0", error.MysqlDurabilityTooWeak);
}

test "store.mysql live admission refuses statement binlogging" {
    try refusesGlobal("binlog_format", "STATEMENT", error.MysqlStatementBinlog);
}

const store_core = @import("Store.zig");
const store_access = @import("access.zig");
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

test "store.mysql live midchunk stop pads its frame and rollback leaves connection usable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: Store = undefined;
    try openLive(&storage, &tmp);
    defer storage.close() catch unreachable;
    const mysql = &storage.engine.mysql;
    defer if (mysql.inTransaction()) mysql.control(.rollback) catch unreachable;
    try mysql.control(.begin);
    const length = @import("engine/mysql_content.zig").chunk_bytes + 17;
    _ = try liveWrite(&storage, live_insert, .{ .id = 9000020, .digest = protocol.contentDigest("stopped-midchunk"), .length = length });
    const sink = try mysql.openSink(9000020, length);
    const before = mysql.state.connection.queries;
    try sink.write("partial", 0);
    // The source stops here. close must finish only the current framed
    // chunk, not send the second chunk or fence this ordinary input stop.
    sink.close();
    try std.testing.expectEqual(@as(u64, 1), mysql.state.connection.queries - before);
    try std.testing.expect(mysql.state.connection.isReady());
    try std.testing.expect(mysql.state.failure == null);
    try mysql.control(.rollback);
    try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content WHERE content_id=9000020", .{}));
    try std.testing.expectEqual(@as(u64, 0), try queryU64(&storage, "SELECT count(*) FROM content_chunk WHERE content_id=9000020", .{}));
    try std.testing.expectEqual(@as(u64, 1), try liveWrite(&storage, live_noop, .{}));
    try std.testing.expect(!storage.isFenced());
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
            const n = try file.readStreaming(std.testing.io, &.{buffer[filled..]});
            if (n == 0) return parse(buffer[0..filled]);
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
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
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

test "Linux memory observation parses all four exact KiB counters" {
    const sample = try LinuxMemory.parse("0000-ffff [rollup]\nRss: 31 kB\nPss: 23 kB\nPrivate_Dirty: 17 kB\nAnonymous: 11 kB\nOther: 7 kB\n");
    try std.testing.expectEqual(@as(u64, 17), sample.private_dirty_kib);
    try std.testing.expectEqual(@as(u64, 11), sample.anonymous_kib);
    try std.testing.expectEqual(@as(u64, 23), sample.pss_kib);
    try std.testing.expectEqual(@as(u64, 31), sample.rss_kib);
    try std.testing.expectError(error.IncompleteSmapsRollup, LinuxMemory.parse("Private_Dirty: 17 kB\n"));
    try std.testing.expectError(error.InvalidSmapsRollup, LinuxMemory.parse("Private_Dirty: 17 MB\n"));
}
