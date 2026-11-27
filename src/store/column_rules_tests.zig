const std = @import("std");
const schema = @import("schema.zig");
const rsql = @import("rsql.zig");
const engine = @import("engine.zig");
const column_rules = @import("column_rules.zig");
const char_set = @import("rules/char_set.zig");
const rules = @import("rules/rule.zig");
const evaluator = @import("rules/eval.zig");
const Value = column_rules.Value;
const accepts = column_rules.accepts;
const admit = engine.admit;
const sqlite = @import("sqlite.zig");
const mysql_testing = @import("mysql_testing.zig");
const store_check = @import("store_check.zig");
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
                    for (multibyte, 0..) |*byte, at| byte.* = if (at + 1 == length and length % 2 == 1) 'a' else if (at % 2 == 0) 0xc3 else 0xa9;
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
                    try std.testing.expectEqual(stored, accepts(column, value));
                    checked += 1;
                }
            }
        }
    }
    try std.testing.expect(checked > 1000);
}

fn wordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// Whether `name` appears in `text` as a whole word.
fn mentions(comptime text: []const u8, comptime name: []const u8) bool {
    comptime {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, name)) |found| : (at = found + 1) {
            const end = found + name.len;
            if ((found == 0 or !wordByte(text[found - 1])) and (end == text.len or !wordByte(text[end]))) return true;
        }
        return false;
    }
}

/// The columns of `table` a rule's text reads.
fn readBy(comptime table: schema.Table, comptime text: []const u8) []const schema.Column {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const schema.Column = &.{};
        for (table.columns) |column| if (mentions(text, column.name)) {
            out = out ++ &[_]schema.Column{column};
        };
        return out;
    }
}

/// Small values for one column: NULL, the edges, and every literal the rule names.
fn smallDomain(comptime column: schema.Column, comptime text: []const u8) []const evaluator.Value {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var out: []const evaluator.Value = &.{.null};
        switch (column.type) {
            .int, .flag => out = out ++ &[_]evaluator.Value{ .{ .int = 0 }, .{ .int = 1 }, .{ .int = 2 } },
            .text, .tag, .bytes => {
                out = out ++ &[_]evaluator.Value{ .{ .text = "" }, .{ .text = "x" }, .{ .text = "a" }, .{ .text = "-" } };
                var open: ?usize = null;
                for (text, 0..) |byte, at| if (byte == '\'') {
                    if (open) |start| {
                        out = out ++ &[_]evaluator.Value{.{ .text = text[start + 1 .. at] }};
                        open = null;
                    } else open = at;
                };
            },
        }
        return out;
    }
}

fn bindValue(statement: *c.sqlite3_stmt, index: c_int, column: schema.Column, value: evaluator.Value) !void {
    switch (value) {
        .null => _ = c.sqlite3_bind_null(statement, index),
        .int => |number| try sqlite.bindI64(statement, index, number),
        .text => |bytes| if (column.type == .bytes) try sqlite.bindBlob(statement, index, bytes) else try sqlite.bindText(statement, index, bytes),
    }
}

/// Every row over the small domains of the columns `rule` reads: the evaluator never errors and answers what SQLite answers.
fn agreeWithSqlite(database: *c.sqlite3, comptime table: schema.Table, comptime rule: rules.Expr, checked: *usize) !void {
    const text = comptime rules.render(rule);
    const read = comptime readBy(table, text);
    const create = comptime blk: {
        var out: []const u8 = "CREATE TABLE probe(";
        for (table.columns, 0..) |column, at| out = out ++ (if (at == 0) "" else ",") ++ column.name ++ " " ++ sqliteType(column);
        break :blk out ++ ")";
    };
    const insert = comptime blk: {
        if (read.len == 0) break :blk "INSERT INTO probe DEFAULT VALUES";
        var names: []const u8 = "";
        var marks: []const u8 = "";
        for (read, 0..) |column, at| {
            names = names ++ (if (at == 0) "" else ",") ++ column.name;
            marks = marks ++ (if (at == 0) "" else ",") ++ std.fmt.comptimePrint("?{d}", .{at + 1});
        }
        break :blk "INSERT INTO probe(" ++ names ++ ") VALUES(" ++ marks ++ ")";
    };
    const select = comptime "SELECT " ++ rsql.render(.sqlite, "(" ++ text ++ ")") ++ " FROM probe";
    const names = comptime blk: {
        var out: [read.len][]const u8 = undefined;
        for (read, 0..) |column, at| out[at] = column.name;
        break :blk out;
    };
    const domains = comptime blk: {
        var out: [read.len][]const evaluator.Value = undefined;
        for (read, 0..) |column, at| out[at] = smallDomain(column, text);
        break :blk out;
    };
    try sqlite.exec(database, "DROP TABLE IF EXISTS probe");
    try sqlite.exec(database, create);
    var index: [read.len]usize = @splat(0);
    while (true) {
        var row: [read.len]evaluator.Value = undefined;
        inline for (domains, 0..) |domain, at| row[at] = domain[index[at]];
        try sqlite.exec(database, "DELETE FROM probe");
        {
            const statement = try sqlite.prepare(database, insert);
            defer _ = c.sqlite3_finalize(statement);
            inline for (read, 0..) |column, at| try bindValue(statement, @intCast(at + 1), column, row[at]);
            try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(statement));
        }
        const statement = try sqlite.prepare(database, select);
        defer _ = c.sqlite3_finalize(statement);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(statement));
        const expected: evaluator.Value = if (c.sqlite3_column_type(statement, 0) == c.SQLITE_NULL) .null else .{ .int = @intFromBool(c.sqlite3_column_int64(statement, 0) != 0) };
        const got = try evaluator.eval(&rule, evaluator.Scope.ofRow(.{}, "", &names, &row));
        const normal: evaluator.Value = if (got == .int) .{ .int = @intFromBool(got.int != 0) } else got;
        std.testing.expectEqualDeep(expected, normal) catch |failure| {
            std.debug.print("rule {s} disagrees with SQLite on row {any}\n", .{ text, row });
            return failure;
        };
        checked.* += 1;
        var at: usize = read.len;
        while (at > 0) {
            at -= 1;
            index[at] += 1;
            if (index[at] < domains[at].len) break;
            index[at] = 0;
        } else break;
    }
}

test "SH-180 every CHECK rule value answers over a row as SQLite does, and never errors" {
    var database: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &database));
    defer _ = c.sqlite3_close(database);
    var checked: usize = 0;
    var rules_seen: usize = 0;
    inline for (schema.tables) |table| {
        if (comptime !table.engines.on(.sqlite)) continue;
        inline for (table.columns) |column| if (comptime column.check) |rule| {
            try agreeWithSqlite(database.?, table, rule, &checked);
            rules_seen += 1;
        };
        inline for (table.checks) |rule| {
            try agreeWithSqlite(database.?, table, rule, &checked);
            rules_seen += 1;
        }
    }
    try std.testing.expect(rules_seen > 60);
    try std.testing.expect(checked > 1000);
}

test "SH-180 a call with the wrong shape is an error whatever the row holds" {
    const n: evaluator.Value = .null;
    const bad_arity = comptime rules.Expr{ .call = .{ .name = .initial, .args = &.{rules.field("s")} } };
    try std.testing.expectError(error.BadCall, evaluator.eval(&bad_arity, evaluator.Scope.ofRow(.{}, "", &.{"s"}, &.{n})));
    const not_a_set = comptime rules.call(.charset, &.{ rules.field("s"), rules.field("s") });
    try std.testing.expectError(error.BadCall, evaluator.eval(&not_a_set, evaluator.Scope.ofRow(.{}, "", &.{"s"}, &.{n})));
    const length_of_int = comptime rules.call(.length, &.{rules.field("s")});
    try std.testing.expectError(error.BadCall, evaluator.eval(&length_of_int, evaluator.Scope.ofRow(.{}, "", &.{"s"}, &.{.{ .int = 1 }})));
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
                    try std.testing.expectEqual(stored, accepts(column, value));
                    checked += 1;
                }
            }
        }
    }
    _ = try mysql_testing.takes("DROP TABLE IF EXISTS rui_column_probe");
    try std.testing.expect(checked > 1000);
}

test "SH-178 a set of ranges and literals holds the bytes it names, and its neighbours are outside it" {
    try std.testing.expect(char_set.inSet("a-z0-9_-", 'a') and char_set.inSet("a-z0-9_-", 'z') and char_set.inSet("a-z0-9_-", '0') and char_set.inSet("a-z0-9_-", '9'));
    try std.testing.expect(char_set.inSet("a-z0-9_-", '_') and char_set.inSet("a-z0-9_-", '-'));
    for ("`{A/:@[ ") |outside| try std.testing.expect(!char_set.inSet("a-z0-9_-", outside));
}

test "SH-178 a byte set holds its ranges and literals, a leading or trailing dash, and nothing for an empty set or subject" {
    try std.testing.expect(char_set.inSet("-a-c", '-'));
    try std.testing.expect(char_set.inSet("-a-c", 'b'));
    try std.testing.expect(!char_set.inSet("-a-c", 'd'));
    try std.testing.expect(char_set.inSet("a-c-", '-'));
    try std.testing.expect(char_set.inSet("0-9", '0') and char_set.inSet("0-9", '9') and !char_set.inSet("0-9", ':'));
    try std.testing.expect(!char_set.inSet("", 'a'));
}

/// One content_part row that breaks a column rule (ordinal below 0), a cross-column rule (a part that is its own
/// container) and both references (no content row 5), so every kind of check has exactly one violator to find.
const broken_part = "INSERT INTO content_part(content_id,ordinal,part_content_id) VALUES(5,-1,5)";

fn violatorsOf(name: []const u8, broken: bool) u32 {
    if (!broken) return 0;
    const hit = [_][]const u8{ "content_part.ordinal", "content_part#0", "content_part(content_id)->content", "content_part(part_content_id)->content" };
    for (hit) |each| if (std.mem.eql(u8, name, each)) return 1;
    return 0;
}

test "SH-183 store check counts the rows that break a column rule, a cross-column rule and a reference in a plain SQLite Store" {
    var raw: ?*c.sqlite3 = null;
    defer _ = c.sqlite3_close(raw);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(":memory:", &raw));
    const database = raw.?;
    try sqlite.exec(database, schema.ddlIn(.sqlite, .plain));
    const all = comptime store_check.checks(.sqlite);
    var seen: [3]bool = @splat(false);
    for (all) |check| {
        try std.testing.expectEqual(@as(u32, 0), try sqlite.pragmaInt(database, check.sql));
        seen[@backingInt(check.kind)] = true;
    }
    try std.testing.expectEqual([_]bool{ true, true, true }, seen);
    try sqlite.exec(database, broken_part);
    for (all) |check| try std.testing.expectEqual(violatorsOf(check.name, true), try sqlite.pragmaInt(database, check.sql));
}

test "SH-183 store check's statements run on MySQL and count the rows that break each kind of rule" {
    if (!try mysql_testing.available()) return;
    try std.testing.expect(try mysql_testing.takes("DROP DATABASE IF EXISTS rui_store_check_probe"));
    try std.testing.expect(try mysql_testing.takes("CREATE DATABASE rui_store_check_probe DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_0900_bin"));
    defer _ = mysql_testing.takes("DROP DATABASE IF EXISTS rui_store_check_probe") catch false;
    try std.testing.expect(try mysql_testing.takes("USE rui_store_check_probe"));
    inline for (comptime schema.plainObjects(.mysql)) |object| try std.testing.expect(try mysql_testing.takes(object.sql));
    const all = comptime store_check.checks(.mysql);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]bool{ false, true }) |broken| {
        if (broken) try std.testing.expect(try mysql_testing.takes(broken_part));
        for (all) |check| {
            // A scalar subquery that finds two rows is refused, so the statement is taken exactly when the count is the one expected.
            const asks = try std.fmt.allocPrint(arena, "SELECT IF(({s})={d},1,(SELECT 1 UNION SELECT 2))", .{ check.sql, violatorsOf(check.name, broken) });
            if (!try mysql_testing.takes(asks)) {
                std.debug.print("store check {s} did not count {d}\n", .{ check.name, violatorsOf(check.name, broken) });
                return error.WrongViolatorCount;
            }
        }
    }
}
