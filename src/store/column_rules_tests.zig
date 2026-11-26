const std = @import("std");
const schema = @import("schema.zig");
const rsql = @import("rsql.zig");
const engine = @import("engine.zig");
const column_rules = @import("column_rules.zig");
const Value = column_rules.Value;
const accepts = column_rules.accepts;
const admit = engine.admit;
const sqlite = @import("sqlite.zig");
const mysql_testing = @import("mysql_testing.zig");
const c = sqlite.c;

fn ruleSql(comptime table: []const u8, comptime column: schema.Column) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(100_000_000);
        return schema.columnRuleSql(.sqlite, table, column);
    }
}

fn sqliteType(comptime column: schema.Column) []const u8 {
    return switch (column.type) {
        .int, .flag => "INTEGER",
        .text, .tag => "TEXT",
        .bytes => "BLOB",
    };
}

/// Values at and around every edge a column's own rules draw.
fn candidates(comptime column: schema.Column, out: *std.ArrayList(Value), arena: std.mem.Allocator) !void {
    try out.append(arena, .null);
    switch (column.type) {
        .int, .flag => {
            const edges = [_]i64{ -1, 0, 1, 2, 3, 4, 5, 6, 7, 63, 64, 1024, 4294967295, 4294967296, 1073737728, 1073737729 };
            for (edges) |edge| try out.append(arena, .{ .int = edge });
            if (column.range) |range| {
                try out.append(arena, .{ .int = range.min - 1 });
                try out.append(arena, .{ .int = range.min });
                try out.append(arena, .{ .int = range.min + 1 });
                if (range.max) |max| {
                    try out.append(arena, .{ .int = max - 1 });
                    try out.append(arena, .{ .int = max });
                    try out.append(arena, .{ .int = max + 1 });
                }
            }
        },
        .text, .bytes => {
            const bounds: schema.Octets = switch (column.type) {
                .text, .bytes => |octets| octets orelse .{ .max = 8 },
                else => unreachable,
            };
            const good = if (column.charset) |set| set[0] else 'a';
            const first = if (column.initial) |set| set[0] else good;
            const lengths = [_]u32{ 0, 1, bounds.min -| 1, bounds.min, bounds.min + 1, bounds.max -| 1, bounds.max, bounds.max + 1 };
            for (lengths) |length| {
                const bytes = try arena.alloc(u8, length);
                @memset(bytes, good);
                if (length > 0) bytes[0] = first;
                try out.append(arena, .{ .octets = bytes });
                if (length > 0 and (column.charset != null or column.initial != null)) {
                    // Every printable byte at the lead and at the end, so each range edge, literal and neighbour of a set is probed.
                    var byte: u8 = 32;
                    while (byte < 127) : (byte += 1) {
                        if (byte == '\'') continue;
                        const lead = try arena.dupe(u8, bytes);
                        lead[0] = byte;
                        try out.append(arena, .{ .octets = lead });
                        const tail = try arena.dupe(u8, bytes);
                        tail[length - 1] = byte;
                        try out.append(arena, .{ .octets = tail });
                    }
                    const accent = try arena.dupe(u8, "\xc3\xa9");
                    try out.append(arena, .{ .octets = accent });
                } else if (length > 0) {
                    const multibyte = try arena.alloc(u8, length);
                    for (multibyte, 0..) |*byte, at| byte.* = if (at % 2 == 0) 0xc3 else 0xa9;
                    try out.append(arena, .{ .octets = multibyte });
                }
            }
        },
        .tag => |values| {
            for (values) |value| try out.append(arena, .{ .octets = value });
            try out.append(arena, .{ .octets = "" });
            try out.append(arena, .{ .octets = "unlisted" });
            for (values) |value| {
                try out.append(arena, .{ .octets = try std.ascii.allocUpperString(arena, value) });
                try out.append(arena, .{ .octets = try std.fmt.allocPrint(arena, "{s} ", .{value}) });
                if (value.len > 1) try out.append(arena, .{ .octets = value[0 .. value.len - 1] });
            }
        },
    }
}

test "SH-178 a column's own rules are held by the Host as SQLite's CHECK holds them" {
    var database: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &database));
    defer _ = c.sqlite3_close(database);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var checked: usize = 0;
    inline for (schema.tables) |table| {
        if (comptime !table.engines.on(.sqlite)) continue;
        inline for (table.columns) |each| {
            if (comptime !each.engines.on(.sqlite)) continue;
            const column = comptime blk: {
                var own = each;
                own.check = null;
                break :blk own;
            };
            if (comptime ruleSql(table.name, column)) |rule| {
                const create = comptime "CREATE TABLE probe(" ++ column.name ++ " " ++ sqliteType(column) ++ (if (column.nullable) "" else " NOT NULL") ++ " CHECK(" ++ rule ++ ")) STRICT";
                try sqlite.exec(database.?, "DROP TABLE IF EXISTS probe");
                try sqlite.exec(database.?, create);
                var values: std.ArrayList(Value) = .empty;
                try candidates(column, &values, arena);
                for (values.items) |value| {
                    const statement = try sqlite.prepare(database.?, "INSERT INTO probe(" ++ column.name ++ ") VALUES(?1)");
                    defer _ = c.sqlite3_finalize(statement);
                    switch (value) {
                        .null => _ = c.sqlite3_bind_null(statement, 1),
                        .int => |number| try sqlite.bindI64(statement, 1, number),
                        .octets => |bytes| if (column.type == .bytes) try sqlite.bindBlob(statement, 1, bytes) else try sqlite.bindText(statement, 1, bytes),
                    }
                    const stored = c.sqlite3_step(statement) == c.SQLITE_DONE;
                    std.testing.expectEqual(stored, accepts(column, value)) catch |err| {
                        const text = try std.fmt.allocPrint(arena, "{s}.{s}: {any} rule({s}) engine took={}\n{s}\n", .{ table.name, column.name, value, rule, stored, insert });
                        std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "/tmp/col3.txt", .data = text[0..@min(text.len, 3000)] }) catch {};
                        return err;
                    };
                    checked += 1;
                }
            }
        }
    }
    try std.testing.expect(checked > 1000);
}

const key_fits: [128]u8 = @splat('k');
const key_long: [129]u8 = @splat('k');

test "SH-179 a statement binding a value to a column the column refuses fails before anything is sent" {
    const Command = struct { key: []const u8, kind: u64, target: []const u8 };
    const W = rsql.Write(.{
        .sql = "INSERT INTO core_command(command_key,kind,target) VALUES(?1,?2,?3)",
        .Args = Command,
        .expect = .{ .at_most = 1 },
    });
    try std.testing.expectEqual(@as(usize, 3), W.bound_columns.len);
    const head: rsql.SessionHead = undefined;
    var command: Command = .{ .key = &key_fits, .kind = 1, .target = "t" };
    try admit(W, &command);
    command.key = &key_long;
    try std.testing.expectError(error.ColumnRuleRefused, admit(W, &command));
    command.key = "k";
    command.kind = 10;
    try std.testing.expectError(error.ColumnRuleRefused, admit(W, &command));
    const UpdateArgs = struct { label: ?[]const u8, session: rsql.SessionHead };
    const Update = rsql.Write(.{
        .sql = "UPDATE session SET label=?1 WHERE session_ref=@session(?2)",
        .Args = UpdateArgs,
        .expect = .{ .at_most = 1 },
    });
    var update: UpdateArgs = .{ .label = null, .session = head };
    try admit(Update, &update);
    update.label = "x";
    try admit(Update, &update);
    update.label = "";
    try std.testing.expectError(error.ColumnRuleRefused, admit(Update, &update));

    const Owe = rsql.Write(.{
        .sql = "INSERT INTO session_stop_owed(child_ref,cause_ref,cause_position,settled) SELECT child.session_ref,?1,?2,0 FROM session child " ++
            "WHERE child.parent_ref=?1 AND NOT EXISTS(SELECT 1 FROM session_stop_owed owed WHERE owed.child_ref=child.session_ref AND owed.settled=0)",
        .Args = struct { parent: []const u8, position: u64 },
        .expect = .{ .counted = .{ .otherwise = error.CorruptStore } },
    });
    try std.testing.expectEqual(@as(usize, 2), Owe.bound_columns.len);
    var owed: Owe.Args = .{ .parent = "abcdef", .position = 1 };
    try admit(Owe, &owed);
    owed.position = 0;
    try std.testing.expectError(error.ColumnRuleRefused, admit(Owe, &owed));
}

fn mysqlRuleSql(comptime table: []const u8, comptime column: schema.Column) ?[]const u8 {
    comptime {
        @setEvalBranchQuota(100_000_000);
        return schema.columnRuleSql(.mysql, table, column);
    }
}

fn mysqlType(comptime column: schema.Column) []const u8 {
    return switch (column.type) {
        .int, .flag => "BIGINT",
        .text, .tag => "LONGTEXT COLLATE utf8mb4_0900_bin",
        .bytes => "LONGBLOB",
    };
}

fn mysqlLiteral(arena: std.mem.Allocator, comptime column: schema.Column, value: Value) ![]const u8 {
    return switch (value) {
        .null => "NULL",
        .int => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        .octets => |bytes| blk: {
            if (column.type == .bytes) break :blk try std.fmt.allocPrint(arena, "X'{x}'", .{bytes});
            break :blk try std.fmt.allocPrint(arena, "'{s}'", .{bytes});
        },
    };
}

test "SH-178 a column's own rules are held by the Host as MySQL's CHECK holds them" {
    if (!try mysql_testing.available()) return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var checked: usize = 0;
    inline for (schema.tables) |table| {
        if (comptime !table.engines.on(.mysql)) continue;
        inline for (table.columns) |each| {
            if (comptime !each.engines.on(.mysql)) continue;
            const column = comptime blk: {
                var own = each;
                own.check = null;
                break :blk own;
            };
            if (comptime mysqlRuleSql(table.name, column)) |rule| {
                const create = comptime "CREATE TABLE rui_column_probe(" ++ column.name ++ " " ++ mysqlType(column) ++ (if (column.nullable) "" else " NOT NULL") ++ ", CHECK(" ++ rule ++ "))";
                try std.testing.expect(try mysql_testing.takes("DROP TABLE IF EXISTS rui_column_probe"));
                try std.testing.expect(try mysql_testing.takes(create));
                var values: std.ArrayList(Value) = .empty;
                try candidates(column, &values, arena);
                for (values.items) |value| {
                    const insert = try std.fmt.allocPrint(arena, "INSERT INTO rui_column_probe(" ++ column.name ++ ") VALUES({s})", .{try mysqlLiteral(arena, column, value)});
                    const stored = try mysql_testing.takes(insert);
                    std.testing.expectEqual(stored, accepts(column, value)) catch |err| {
                        const text = try std.fmt.allocPrint(arena, "{s}.{s}: {any} rule({s}) engine took={}\n{s}\n", .{ table.name, column.name, value, rule, stored, insert });
                        std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = "/tmp/col3.txt", .data = text[0..@min(text.len, 3000)] }) catch {};
                        return err;
                    };
                    checked += 1;
                }
            }
        }
    }
    _ = try mysql_testing.takes("DROP TABLE IF EXISTS rui_column_probe");
    try std.testing.expect(checked > 1000);
}

test "SH-178 a set of ranges and literals holds the bytes it names, and its neighbours are outside it" {
    try std.testing.expect(column_rules.inSet("a-z0-9_-", 'a') and column_rules.inSet("a-z0-9_-", 'z') and column_rules.inSet("a-z0-9_-", '0') and column_rules.inSet("a-z0-9_-", '9'));
    try std.testing.expect(column_rules.inSet("a-z0-9_-", '_') and column_rules.inSet("a-z0-9_-", '-'));
    for ("`{A/:@[ ") |outside| try std.testing.expect(!column_rules.inSet("a-z0-9_-", outside));
}
