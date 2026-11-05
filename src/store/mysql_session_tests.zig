//! The MySQL session layer against a live MySQL 8.4 server: every Args
//! type as a literal (`mysql_literal.zig`), INSERTed and SELECTed back
//! through the connection (`wire/mysql_connection.zig`) into every Row type
//! (`mysql_row.zig`), extremes included, and compared.
//!
//! The server is the one `mysql_dialect_check.zig` uses, named the same way
//! (`RUI_TEST_MYSQL_SOCKET`, `RUI_TEST_MYSQL_ROOT_PASSWORD`). Without it each
//! test skips, unless `RUI_TEST_REQUIRE_ENGINES` lists `mysql`; then it fails.
//! The tests work in their own database, `rui_session_check`.
const std = @import("std");
const Bounded = @import("../bounded.zig").Bounded;
const protocol = @import("../protocol.zig");
const rsql = @import("rsql.zig");
const schema = @import("schema.zig");
const literal = @import("mysql_literal.zig");
const row_decoder = @import("mysql_row.zig");
const mysql_dialect_check = @import("mysql_dialect_check.zig");
const mysql_connection = @import("wire/mysql_connection.zig");
const Connection = mysql_connection.Connection;

const database = "rui_session_check";

/// A root connection on the check's fresh database, or null to skip.
fn open(connection: *Connection) !?void {
    const config = try mysql_dialect_check.rootConfig() orelse return null;
    var refusal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer refusal.deinit();
    connection.open(.{ .address = .{ .unix_socket = config.socket }, .user = "root", .password = config.password, .database = "mysql" }, &refusal.writer) catch |err| {
        std.log.err("MySQL session check: root login over {s} failed: {s} {s}", .{ config.socket, @errorName(err), refusal.written() });
        return err;
    };
    errdefer connection.close();
    for (schema.mysql_session) |text| _ = try expectOks(connection, text);
    _ = try expectOks(connection, "DROP DATABASE IF EXISTS " ++ database ++ ";CREATE DATABASE " ++ database ++ ";USE " ++ database ++
        ";CREATE TABLE value_check (id BIGINT PRIMARY KEY, text_value LONGTEXT NULL, bytes_value LONGBLOB NULL," ++
        " count_value BIGINT NULL, flag_value TINYINT NULL, tag_value VARCHAR(16) NULL, digest_value VARBINARY(32) NULL," ++
        " session_ref VARCHAR(6) NULL, workspace_key BIGINT NULL, next_position BIGINT NULL, at_value BIGINT NULL," ++
        " served_value VARCHAR(16) NULL, label_value VARCHAR(64) NULL)");
    return {};
}

/// Runs `text`, whose statements each answer OK; returns the last count.
fn expectOks(connection: *Connection, text: []const u8) !u64 {
    try connection.query(text);
    return okUntilReady(connection);
}

fn okUntilReady(connection: *Connection) !u64 {
    var affected: u64 = 0;
    while (!connection.isReady()) switch (try connection.next()) {
        .ok => |ok| affected = ok.affected_rows,
        .err => |err| {
            std.log.err("MySQL session check: err {d} {s}", .{ err.code, err.message });
            return error.MysqlRefused;
        },
        else => return error.UnexpectedEvent,
    };
    return affected;
}

const served_routes: protocol.Routes = blk: {
    var routes = protocol.routesAll(.unserved);
    routes.codex = .endpoint;
    break :blk routes;
};

fn bound(now: i64) literal.Bound {
    return .{ .now = now, .served = &served_routes };
}

/// Sends `template` with `args` as one streamed COM_QUERY.
fn send(connection: *Connection, comptime template: rsql.Template, comptime Args: type, args: *const Args, now: i64) !void {
    const len = try literal.length(template, Args, args, bound(now));
    const w = try connection.beginQuery(len);
    // A failed write's cause comes from endQuery.
    literal.write(template, Args, args, bound(now), w) catch {};
    try connection.endQuery();
}

/// Reads the one row of the result of the query just sent.
fn readOne(comptime Row: type, connection: *Connection, row: *Row) !void {
    const count = switch (try connection.next()) {
        .columns => |count| count,
        .err => |err| {
            std.log.err("MySQL session check: err {d} {s}", .{ err.code, err.message });
            return error.MysqlRefused;
        },
        else => return error.UnexpectedEvent,
    };
    const columns = try row_decoder.readColumns(Row, connection, count);
    if (try connection.next() != .row) return error.UnexpectedEvent;
    try row_decoder.decodeRow(Row, &columns, connection, row);
    if (try connection.next() != .rows_end) return error.UnexpectedEvent;
    std.debug.assert(connection.isReady());
}

fn rendered(comptime text: []const u8) rsql.Template {
    return comptime rsql.mysqlRendering(text).rendered;
}

const Tag = enum { open, closed_for_good };

const insert_all = rendered("INSERT INTO value_check(id,text_value,bytes_value,count_value,flag_value,tag_value,digest_value," ++
    "session_ref,workspace_key,next_position,at_value,served_value,label_value) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,@now,?11,?12)");
const select_all = rendered("SELECT id,text_value,bytes_value,count_value,flag_value,tag_value,digest_value," ++
    "session_ref,workspace_key,next_position,at_value,@served(served_value),label_value FROM value_check WHERE id=?1");

const Present = struct {
    id: rsql.Positive,
    text: []const u8,
    bytes: rsql.Bytes,
    count: u64,
    flag: bool,
    tag: Tag,
    digest: [32]u8,
    head: rsql.SessionHead,
    workspace_key: rsql.Positive,
    next_position: rsql.Positive,
    served: []const u8,
    label: Bounded(64),
};

const long_bytes = 70_000;
const long_text = 100_000;

const PresentRow = struct {
    id: rsql.Positive,
    text: *Bounded(long_text),
    bytes: *rsql.Blob(long_bytes),
    count: u64,
    flag: bool,
    tag: Tag,
    digest: [32]u8,
    head: rsql.SessionHead,
    at: i64,
    served: bool,
    label: Bounded(64),
};

const Key = struct { id: rsql.Positive };

const now_second: i64 = 1_800_000_000;

fn roundTrip(connection: *Connection, args: *const Present, text: *Bounded(long_text), bytes: *rsql.Blob(long_bytes)) !void {
    try send(connection, insert_all, Present, args, now_second);
    try std.testing.expectEqual(1, try okUntilReady(connection));
    try send(connection, select_all, Key, &.{ .id = args.id }, 0);
    var row: PresentRow = undefined;
    row.text = text;
    row.bytes = bytes;
    try readOne(PresentRow, connection, &row);
    try std.testing.expectEqual(args.id, row.id);
    try std.testing.expectEqualSlices(u8, args.text, text.slice());
    try std.testing.expectEqualSlices(u8, args.bytes.bytes, bytes.slice());
    try std.testing.expectEqual(args.count, row.count);
    try std.testing.expectEqual(args.flag, row.flag);
    try std.testing.expectEqual(args.tag, row.tag);
    try std.testing.expectEqualSlices(u8, &args.digest, &row.digest);
    try std.testing.expectEqualSlices(u8, &args.head.ref, &row.head.ref);
    try std.testing.expectEqual(args.workspace_key, row.head.workspace_key);
    try std.testing.expectEqual(args.next_position, row.head.next_position);
    try std.testing.expectEqual(now_second, row.at);
    const routes_served = if (std.meta.stringToEnum(protocol.Provider, args.served)) |provider| protocol.routeOf(served_routes, provider) != .unserved else false;
    try std.testing.expectEqual(routes_served, row.served);
    try std.testing.expectEqualStrings(args.label.slice(), row.label.slice());
}

test "every Args type round-trips through a literal into its Row type, extremes included" {
    const allocator = std.testing.allocator;
    const connection = try allocator.create(Connection);
    defer allocator.destroy(connection);
    _ = try open(connection) orelse return error.SkipZigTest;
    defer connection.close();
    const text = try allocator.create(Bounded(long_text));
    defer allocator.destroy(text);
    const bytes = try allocator.create(rsql.Blob(long_bytes));
    defer allocator.destroy(bytes);

    // Every byte value; UTF-8 of each width, a quote, a backslash and NUL.
    var all_bytes: [256]u8 = undefined;
    for (&all_bytes, 0..) |*byte, i| byte.* = @intCast(i);
    var label: Bounded(64) = .{ .len = 0 };
    try label.set("a'b\\c\x00é€😀");
    var digest: [32]u8 = undefined;
    for (&digest, 0..) |*byte, i| byte.* = @intCast(255 - i);
    const small: Present = .{
        .id = .of(1),
        .text = "it's \\ \x00 é € 😀",
        .bytes = .{ .bytes = &all_bytes },
        .count = std.math.maxInt(i64),
        .flag = true,
        .tag = .closed_for_good,
        .digest = digest,
        .head = .{ .ref = "abc123".*, .workspace_key = .of(1), .next_position = .of(1) },
        .workspace_key = .of(std.math.maxInt(i64)),
        .next_position = .of(1),
        .served = "codex",
        .label = label,
    };
    try roundTrip(connection, &small, text, bytes);

    // The smallest values, and empty text and bytes, which stay non-NULL.
    var empty = small;
    empty.id = .of(std.math.maxInt(i64));
    empty.text = "";
    empty.bytes = .{ .bytes = "" };
    empty.count = 0;
    empty.flag = false;
    empty.tag = .open;
    empty.served = "openai";
    empty.label = .{ .len = 0 };
    try roundTrip(connection, &empty, text, bytes);

    // Values longer than a batch and than the receive buffer: the INSERT
    // streams through the send buffer, the row through the receive buffer.
    const long_value = try allocator.alloc(u8, long_text);
    defer allocator.free(long_value);
    // Whole characters: the length is a multiple of the pattern's 5 bytes.
    for (long_value, 0..) |*byte, i| byte.* = "é€"[i % 5];
    const long_blob = try allocator.alloc(u8, long_bytes);
    defer allocator.free(long_blob);
    for (long_blob, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    var long = small;
    long.id = .of(2);
    long.text = long_value;
    long.bytes = .{ .bytes = long_blob };
    try roundTrip(connection, &long, text, bytes);
    try std.testing.expect(connection.queries >= 6);
}

const Absent = struct {
    id: rsql.Positive,
    text: ?Bounded(64),
    bytes: ?rsql.Bytes,
    count: ?u32,
    flag: ?bool,
    tag: ?Tag,
    digest: ?[32]u8,
    ref: ?rsql.SessionHead,
    workspace_key: ?rsql.Positive,
    next_position: ?rsql.Positive,
    label: ?[]const u8,
};

const insert_optional = rendered("INSERT INTO value_check(id,text_value,bytes_value,count_value,flag_value,tag_value,digest_value," ++
    "session_ref,workspace_key,next_position,label_value) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)");
const select_optional = rendered("SELECT text_value,bytes_value,count_value,flag_value,tag_value,digest_value," ++
    "session_ref,workspace_key,next_position,label_value,at_value FROM value_check WHERE id=?1");

const AbsentRow = struct {
    text: ?Bounded(64),
    bytes: ?rsql.Blob(8),
    count: ?u32,
    flag: ?bool,
    tag: ?Tag,
    digest: ?[32]u8,
    ref: ?Bounded(6),
    workspace_key: ?rsql.Positive,
    next_position: ?rsql.Positive,
    label: ?Bounded(64),
    at: ?u64,
};

test "optional Args round-trip as NULL and as values into optional Row fields" {
    const allocator = std.testing.allocator;
    const connection = try allocator.create(Connection);
    defer allocator.destroy(connection);
    _ = try open(connection) orelse return error.SkipZigTest;
    defer connection.close();

    const nulls: Absent = .{ .id = .of(10), .text = null, .bytes = null, .count = null, .flag = null, .tag = null, .digest = null, .ref = null, .workspace_key = null, .next_position = null, .label = null };
    try send(connection, insert_optional, Absent, &nulls, 0);
    try std.testing.expectEqual(1, try okUntilReady(connection));
    try send(connection, select_optional, Key, &.{ .id = .of(10) }, 0);
    var row: AbsentRow = undefined;
    try readOne(AbsentRow, connection, &row);
    inline for (@typeInfo(AbsentRow).@"struct".field_names) |name| try std.testing.expect(@field(row, name) == null);

    var text: Bounded(64) = .{ .len = 0 };
    try text.set("x");
    const values: Absent = .{
        .id = .of(11),
        .text = text,
        .bytes = .{ .bytes = "\x00\x01" },
        .count = std.math.maxInt(u32),
        .flag = false,
        .tag = .open,
        .digest = @splat(0),
        .ref = .{ .ref = "zz9999".*, .workspace_key = .of(3), .next_position = .of(4) },
        .workspace_key = .of(3),
        .next_position = .of(4),
        .label = "",
    };
    try send(connection, insert_optional, Absent, &values, 0);
    try std.testing.expectEqual(1, try okUntilReady(connection));
    try send(connection, select_optional, Key, &.{ .id = .of(11) }, 0);
    try readOne(AbsentRow, connection, &row);
    try std.testing.expectEqualStrings("x", row.text.?.slice());
    try std.testing.expectEqualSlices(u8, "\x00\x01", row.bytes.?.slice());
    try std.testing.expectEqual(std.math.maxInt(u32), row.count.?);
    try std.testing.expectEqual(false, row.flag.?);
    try std.testing.expectEqual(Tag.open, row.tag.?);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &row.digest.?);
    try std.testing.expectEqualStrings("zz9999", row.ref.?.slice());
    try std.testing.expectEqual(3, row.workspace_key.?.get());
    try std.testing.expectEqual(4, row.next_position.?.get());
    try std.testing.expectEqualStrings("", row.label.?.slice());
    try std.testing.expectEqual(null, row.at);
}

test "text literals compare binary and without padding, and text that is not UTF-8 is refused" {
    const allocator = std.testing.allocator;
    const connection = try allocator.create(Connection);
    defer allocator.destroy(connection);
    _ = try open(connection) orelse return error.SkipZigTest;
    defer connection.close();

    const same = comptime rendered("SELECT @same(?1,?2),@distinct(?1,?2)");
    const Pair = struct { a: []const u8, b: []const u8 };
    const Same = struct { same: bool, distinct: bool };
    const cases = [_]struct { Pair, bool }{
        .{ .{ .a = "a", .b = "a" }, true },
        .{ .{ .a = "a", .b = "A" }, false },
        .{ .{ .a = "a", .b = "a " }, false },
        .{ .{ .a = "é", .b = "e" }, false },
        .{ .{ .a = "", .b = "" }, true },
    };
    for (cases) |case| {
        try send(connection, same, Pair, &case[0], 0);
        var row: Same = undefined;
        try readOne(Same, connection, &row);
        try std.testing.expectEqual(case[1], row.same);
        try std.testing.expectEqual(!case[1], row.distinct);
    }

    // Two statements in one batch: the second never runs after the first fails.
    const insert = comptime rendered("INSERT INTO value_check(id,text_value) VALUES(?1,?2)");
    const Text = struct { id: rsql.Positive, text: []const u8 };
    const w = connection.batch();
    const bad: Text = .{ .id = .of(20), .text = "\xff" };
    const good: Text = .{ .id = .of(21), .text = "ok" };
    try std.testing.expect(try literal.length(insert, Text, &bad, bound(0)) + 1 + try literal.length(insert, Text, &good, bound(0)) <= connection.batchRoom());
    try literal.write(insert, Text, &bad, bound(0), w);
    try w.writeByte(';');
    try literal.write(insert, Text, &good, bound(0), w);
    try connection.sendBatch();
    const refused = try connection.next();
    try std.testing.expect(refused == .err);
    // 1366: incorrect string value, which strict mode makes an error.
    try std.testing.expectEqual(1366, refused.err.code);
    try std.testing.expect(connection.isReady());
    try connection.query("SELECT count(*) FROM value_check WHERE id IN (20,21)");
    const Count = struct { count: u64 };
    var count: Count = undefined;
    try readOne(Count, connection, &count);
    try std.testing.expectEqual(0, count.count);
}
