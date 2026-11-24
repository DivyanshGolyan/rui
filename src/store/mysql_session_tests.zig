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

pub fn open(connection: *Connection) !?void {
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

fn expectOks(connection: *Connection, text: []const u8) !u64 {
    try connection.query(text);
    return okUntilReady(connection);
}

pub fn okUntilReady(connection: *Connection) !u64 {
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

const served_routes: protocol.Served = blk: {
    var routes: protocol.Served = .{};
    routes.put(protocol.servedEntry(.codex, .endpoint)) catch unreachable;
    break :blk routes;
};

pub fn bound(now: i64) literal.Bound {
    return .{ .now = now, .served = &served_routes };
}

pub fn send(connection: *Connection, comptime template: rsql.Template, comptime Args: type, args: *const Args, now: i64) !void {
    const len = try literal.length(template, Args, args, bound(now));
    const w = try connection.beginQuery(len);
    literal.write(template, Args, args, bound(now), w) catch {};
    try connection.endQuery();
}

pub fn readOne(comptime Row: type, connection: *Connection, row: *Row) !void {
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

pub fn rendered(comptime text: []const u8) rsql.Template {
    return comptime rsql.mysqlRendering(text).rendered;
}

pub const Tag = enum { open, closed_for_good };

const insert_all = rendered("INSERT INTO value_check(id,text_value,bytes_value,count_value,flag_value,tag_value,digest_value," ++
    "session_ref,workspace_key,next_position,at_value,served_value,label_value) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,@now,?11,?12)");
const select_all = rendered("SELECT id,text_value,bytes_value,count_value,flag_value,tag_value,digest_value," ++
    "session_ref,workspace_key,next_position,at_value,@served(served_value),label_value FROM value_check WHERE id=?1");

pub const Present = struct {
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

pub const long_bytes = 70_000;
pub const long_text = 100_000;

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

pub const Key = struct { id: rsql.Positive };

const now_second: i64 = 1_800_000_000;

pub fn roundTrip(connection: *Connection, args: *const Present, text: *Bounded(long_text), bytes: *rsql.Blob(long_bytes)) !void {
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
    const routes_served = served_routes.route(args.served) != .unserved;
    try std.testing.expectEqual(routes_served, row.served);
    try std.testing.expectEqualStrings(args.label.slice(), row.label.slice());
}

pub const Absent = struct {
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

pub const insert_optional = rendered("INSERT INTO value_check(id,text_value,bytes_value,count_value,flag_value,tag_value,digest_value," ++
    "session_ref,workspace_key,next_position,label_value) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)");
pub const select_optional = rendered("SELECT text_value,bytes_value,count_value,flag_value,tag_value,digest_value," ++
    "session_ref,workspace_key,next_position,label_value,at_value FROM value_check WHERE id=?1");

pub const AbsentRow = struct {
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

test "word search streams across MySQL content chunk edges including split UTF-8" {
    const Matcher = @import("../word_search.zig").Matcher;
    const allocator = std.testing.allocator;
    const connection = try allocator.create(Connection);
    defer allocator.destroy(connection);
    _ = try open(connection) orelse return error.SkipZigTest;
    defer connection.close();

    inline for (comptime schema.objects(.mysql)) |object| {
        if (comptime object.kind == .table and
            (std.mem.eql(u8, object.name, "content") or std.mem.eql(u8, object.name, "content_chunk")))
            _ = try expectOks(connection, object.sql);
    }
    const insert_content = comptime rendered("INSERT INTO content(content_id,digest,byte_length,private) VALUES(?1,?2,?3,?4)");
    const Content = struct { id: rsql.Positive, digest: [32]u8, length: u64, private: bool };
    const insert_chunk = comptime rendered("INSERT INTO content_chunk(content_id,chunk_index,bytes) VALUES(?1,?2,?3)");
    const Chunk = struct { id: rsql.Positive, index: u64, bytes: rsql.Bytes };
    const select_chunks = comptime rendered("SELECT content_chunk.bytes FROM content_chunk JOIN content ON content.content_id=content_chunk.content_id WHERE content.content_id=?1 AND content.private=0 ORDER BY content_chunk.chunk_index");
    const cases = [_]struct { query: []const u8, stored: []const u8, left: usize }{
        .{ .query = "start_agent", .stored = "StArT_AgEnT", .left = 5 },
        .{ .query = "café", .stored = "CaFé", .left = 4 },
    };
    const bytes = try allocator.alloc(u8, schema.content_chunk_bytes + 180);
    defer allocator.free(bytes);
    for (cases, 0..) |case, index| {
        @memset(bytes, '.');
        const start = schema.content_chunk_bytes - case.left;
        @memcpy(bytes[start..][0..case.stored.len], case.stored);
        const id: rsql.Positive = .of(@intCast(index + 1));
        try send(connection, insert_content, Content, &.{ .id = id, .digest = @splat(@intCast(index)), .length = bytes.len, .private = false }, 0);
        try std.testing.expectEqual(1, try okUntilReady(connection));
        for (0..2) |chunk_index| {
            const at = chunk_index * schema.content_chunk_bytes;
            const chunk = bytes[at..@min(bytes.len, at + schema.content_chunk_bytes)];
            try send(connection, insert_chunk, Chunk, &.{ .id = id, .index = chunk_index, .bytes = .{ .bytes = chunk } }, 0);
            try std.testing.expectEqual(1, try okUntilReady(connection));
        }

        var matcher: Matcher = undefined;
        matcher.init(case.query);
        try send(connection, select_chunks, Key, &.{ .id = id }, 0);
        const columns = switch (try connection.next()) {
            .columns => |n| n,
            else => return error.UnexpectedEvent,
        };
        const Row = struct { bytes: rsql.Blob(schema.content_chunk_bytes) };
        _ = try row_decoder.readColumns(Row, connection, columns);
        var rows: usize = 0;
        while (true) {
            switch (try connection.next()) {
                .row => {},
                .rows_end => break,
                else => return error.UnexpectedEvent,
            }
            const length = switch (try connection.next()) {
                .value => |n| n orelse return error.UnexpectedEvent,
                else => return error.UnexpectedEvent,
            };
            try std.testing.expectEqual(@as(u32, if (rows == 0) schema.content_chunk_bytes else 180), length);
            var read: usize = 0;
            while (read < length) switch (try connection.next()) {
                .bytes => |window| {
                    try std.testing.expect(window.len <= length - read);
                    matcher.feed(window);
                    read += window.len;
                },
                else => return error.UnexpectedEvent,
            };
            rows += 1;
        }
        try std.testing.expect(connection.isReady());
        try std.testing.expectEqual(@as(usize, 2), rows);
        matcher.finish();
        try std.testing.expectEqual(@as(usize, 1), matcher.count);
        const hit = matcher.hits[0];
        try std.testing.expectEqual(start, hit.raw_offset);
        try std.testing.expectEqual(case.stored.len, hit.length);
        try std.testing.expect(std.unicode.utf8ValidateSlice(hit.snippet.slice()));
        try std.testing.expectEqualStrings(case.stored, hit.snippet.slice()[hit.offset..][0..hit.length]);
    }
}
