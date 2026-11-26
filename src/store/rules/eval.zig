//! The evaluator of a rule value (`rule.zig`) over rows given as plain values, with SQL's three-valued logic. It is the
//! rule's reading for tests and for the Host's checks of a row it holds; the engine reads the rendered text. A rule
//! has no per-rule code here: both this file and the renderer switch on the node kind.
const std = @import("std");
const rule = @import("rule.zig");
const char_set = @import("char_set.zig");

const Expr = rule.Expr;
const Select = rule.Select;

/// A cell. A comparison or connective yields `.int` 1 or 0, and `.null` when SQL's answer is unknown.
pub const Value = union(enum) {
    null,
    int: i64,
    text: []const u8,

    fn flag(on: bool) Value {
        return .{ .int = @intFromBool(on) };
    }

    pub fn isTrue(value: Value) bool {
        return value == .int and value.int != 0;
    }
};

pub const Table = struct {
    name: []const u8,
    columns: []const []const u8,
    rows: []const []const Value,
};

/// Rows a rule's subqueries read, as a test states them.
pub const World = struct { tables: []const Table = &.{} };

pub const Error = error{ UnknownColumn, UnknownTable, ScopeTooDeep, MismatchedRow, BadCall };

const max_frames = 16;

/// One alias in scope: the table it ranges over and its current row, or none for the all-NULL row of a LEFT JOIN miss.
pub const Frame = struct {
    alias: []const u8,
    columns: []const []const u8,
    row: ?[]const Value,
};

/// What a rule reads: the aliases bound so far (a row being checked, then each subquery's rows) and the world.
pub const Scope = struct {
    world: World = .{},
    frames: [max_frames]Frame = undefined,
    len: usize = 0,

    /// A scope that holds the one row a rule is checked against, under `alias`.
    pub fn ofRow(world: World, alias: []const u8, columns: []const []const u8, row: []const Value) Scope {
        var scope: Scope = .{ .world = world };
        scope.frames[0] = .{ .alias = alias, .columns = columns, .row = row };
        scope.len = 1;
        return scope;
    }

    fn with(scope: Scope, frame: Frame) Error!Scope {
        if (scope.len == max_frames) return error.ScopeTooDeep;
        var next = scope;
        next.frames[scope.len] = frame;
        next.len += 1;
        return next;
    }

    fn lookup(scope: Scope, alias: []const u8, name: []const u8) Error!Value {
        var at = scope.len;
        while (at > 0) {
            at -= 1;
            const frame = scope.frames[at];
            if (!std.mem.eql(u8, frame.alias, alias)) continue;
            for (frame.columns, 0..) |column, index| {
                if (!std.mem.eql(u8, column, name)) continue;
                const row = frame.row orelse return .null;
                if (row.len != frame.columns.len) return error.MismatchedRow;
                return row[index];
            }
            return error.UnknownColumn;
        }
        return error.UnknownColumn;
    }
};

/// The value of `expr` in `scope`. A truth value is `.int` 1 or 0, or `.null` for unknown.
pub fn eval(expr: *const Expr, scope: Scope) Error!Value {
    switch (expr.*) {
        .col => |c| return scope.lookup(c.alias, c.name),
        .int => |value| return .{ .int = value },
        .text => |value| return .{ .text = value },
        .null_value => return .null,
        .cmp => |c| return compare(c.op, try eval(c.left, scope), try eval(c.right, scope)),
        .is_null => |value| return Value.flag((try eval(value, scope)) == .null),
        .is_not_null => |value| return Value.flag((try eval(value, scope)) != .null),
        .not => |value| {
            const inner = try eval(value, scope);
            return if (inner == .null) .null else Value.flag(!inner.isTrue());
        },
        .all => |parts| {
            var unknown = false;
            for (parts) |*part| {
                const value = try eval(part, scope);
                if (value == .null) unknown = true else if (!value.isTrue()) return Value.flag(false);
            }
            return if (unknown) .null else Value.flag(true);
        },
        .any => |parts| {
            var unknown = false;
            for (parts) |*part| {
                const value = try eval(part, scope);
                if (value == .null) unknown = true else if (value.isTrue()) return Value.flag(true);
            }
            return if (unknown) .null else Value.flag(false);
        },
        .one_of => |s| {
            const subject = try eval(s.value, scope);
            if (subject == .null) return .null;
            for (s.set) |member| if (subject == .text and std.mem.eql(u8, subject.text, member)) return Value.flag(true);
            return Value.flag(false);
        },
        .coalesce => |parts| {
            for (parts) |*part| {
                const value = try eval(part, scope);
                if (value != .null) return value;
            }
            return .null;
        },
        .group => |inner| return eval(inner, scope),
        .between => |b| {
            const value = try eval(b.value, scope);
            const low = compare(.ge, value, try eval(b.low, scope));
            const high = compare(.le, value, try eval(b.high, scope));
            return conjunction(low, high);
        },
        .in_list => |l| {
            const subject = try eval(l.value, scope);
            var unknown = subject == .null;
            for (l.items) |*item| {
                const match = compare(.eq, subject, try eval(item, scope));
                if (match == .null) unknown = true else if (match.isTrue()) return Value.flag(true);
            }
            return if (unknown) .null else Value.flag(false);
        },
        .call => |c| return callValue(c, scope),
        .exists => |query| return Value.flag(try matches(query, scope, true) > 0),
        .not_exists => |query| return Value.flag(try matches(query, scope, true) == 0),
        .count => |query| return .{ .int = @intCast(try matches(query, scope, false)) },
    }
}

fn conjunction(a: Value, b: Value) Value {
    if ((a != .null and !a.isTrue()) or (b != .null and !b.isTrue())) return Value.flag(false);
    return if (a == .null or b == .null) .null else Value.flag(true);
}

/// The functions and rsql macros a rule may call. `@same` and `@distinct` never answer unknown; the rest are unknown for NULL.
fn callValue(c: Expr.Call, scope: Scope) Error!Value {
    const is = std.mem.eql;
    if (is(u8, c.name, "@same") or is(u8, c.name, "@distinct")) {
        if (c.args.len != 2) return error.BadCall;
        const a = try eval(&c.args[0], scope);
        const b = try eval(&c.args[1], scope);
        const same = if (a == .null or b == .null) a == .null and b == .null else compare(.eq, a, b).isTrue();
        return Value.flag(same == is(u8, c.name, "@same"));
    }
    if (c.args.len == 0) return error.BadCall;
    const subject = try eval(&c.args[0], scope);
    if (subject == .null) return .null;
    if (is(u8, c.name, "length") or is(u8, c.name, "@octets")) {
        if (c.args.len != 1 or subject != .text) return error.BadCall;
        return .{ .int = @intCast(subject.text.len) };
    }
    if (c.args.len != 2 or subject != .text or c.args[1] != .text) return error.BadCall;
    const set = c.args[1].text;
    if (is(u8, c.name, "@initial")) return Value.flag(subject.text.len != 0 and char_set.inSet(set, subject.text[0]));
    if (is(u8, c.name, "@charset")) {
        for (subject.text) |byte| if (!char_set.inSet(set, byte)) return Value.flag(false);
        return Value.flag(true);
    }
    return error.BadCall;
}

fn compare(op: Expr.Op, left: Value, right: Value) Value {
    if (left == .null or right == .null) return .null;
    const order: std.math.Order = switch (left) {
        .int => |a| if (right == .int) std.math.order(a, right.int) else return .null,
        .text => |a| if (right == .text) std.mem.order(u8, a, right.text) else return .null,
        .null => unreachable,
    };
    return Value.flag(switch (op) {
        .eq => order == .eq,
        .ne, .bang_ne => order != .eq,
        .lt => order == .lt,
        .le => order != .gt,
        .gt => order == .gt,
        .ge => order != .lt,
    });
}

/// How many rows of `query` satisfy its WHERE, stopping at the first when `first_only`.
fn matches(query: *const Select, scope: Scope, first_only: bool) Error!usize {
    const table = try find(scope.world, query.table);
    var found: usize = 0;
    for (table.rows) |row| {
        const base = try scope.with(.{ .alias = query.alias, .columns = table.columns, .row = row });
        found += try joined(query, base, 0, first_only);
        if (first_only and found > 0) return found;
    }
    return found;
}

/// Each way the joins from `at` on bind a row (or the all-NULL row on a miss), counted when the WHERE holds.
fn joined(query: *const Select, scope: Scope, at: usize, first_only: bool) Error!usize {
    if (at == query.joins.len) return if ((try eval(&query.where, scope)).isTrue()) 1 else 0;
    const join = query.joins[at];
    const table = try find(scope.world, join.table);
    var found: usize = 0;
    var any_match = false;
    for (table.rows) |row| {
        const next = try scope.with(.{ .alias = join.alias, .columns = table.columns, .row = row });
        if (!(try eval(&join.on, next)).isTrue()) continue;
        any_match = true;
        found += try joined(query, next, at + 1, first_only);
        if (first_only and found > 0) return found;
    }
    if (!any_match) {
        const next = try scope.with(.{ .alias = join.alias, .columns = table.columns, .row = null });
        found += try joined(query, next, at + 1, first_only);
    }
    return found;
}

fn find(world: World, name: []const u8) Error!Table {
    for (world.tables) |table| if (std.mem.eql(u8, table.name, name)) return table;
    return error.UnknownTable;
}

const col = rule.col;
const int = rule.int;
const n: Value = .null;

fn i(value: i64) Value {
    return .{ .int = value };
}

fn checks(comptime expr: Expr, columns: []const []const u8, row: []const Value) !Value {
    return eval(&expr, Scope.ofRow(.{}, "t", columns, row));
}

test "a comparison with NULL is unknown, and unknown joins AND and OR as SQL says" {
    const cols = [_][]const u8{ "a", "b" };
    const a_is_1 = comptime rule.eq(col("t", "a"), int(1));
    const b_is_2 = comptime rule.eq(col("t", "b"), int(2));
    const both = comptime rule.all(&.{ a_is_1, b_is_2 });
    const either = comptime rule.any(&.{ a_is_1, b_is_2 });
    // a=1, b=NULL: true AND unknown = unknown; true OR unknown = true.
    try std.testing.expectEqual(n, try checks(both, &cols, &.{ i(1), n }));
    try std.testing.expectEqual(i(1), try checks(either, &cols, &.{ i(1), n }));
    // a=0, b=NULL: false AND unknown = false; false OR unknown = unknown.
    try std.testing.expectEqual(i(0), try checks(both, &cols, &.{ i(0), n }));
    try std.testing.expectEqual(n, try checks(either, &cols, &.{ i(0), n }));
    try std.testing.expectEqual(n, try checks(comptime rule.not(a_is_1), &cols, &.{ n, n }));
}

test "a boolean equality of two null tests is the both-or-neither rule" {
    const cols = [_][]const u8{ "outcome_code", "outcome_at" };
    const both_or_neither = comptime rule.eq(rule.isNull(col("t", "outcome_code")), rule.isNull(col("t", "outcome_at")));
    try std.testing.expect((try checks(both_or_neither, &cols, &.{ n, n })).isTrue());
    try std.testing.expect((try checks(both_or_neither, &cols, &.{ .{ .text = "x" }, i(5) })).isTrue());
    try std.testing.expect(!(try checks(both_or_neither, &cols, &.{ .{ .text = "x" }, n })).isTrue());
}

test "a set matches a text exactly and is unknown for NULL" {
    const cols = [_][]const u8{"code"};
    const in_set = comptime rule.oneOf(col("t", "code"), &.{ "a", "b", "c" });
    try std.testing.expectEqual(i(1), try checks(in_set, &cols, &.{.{ .text = "b" }}));
    try std.testing.expectEqual(i(0), try checks(in_set, &cols, &.{.{ .text = "z" }}));
    try std.testing.expectEqual(n, try checks(in_set, &cols, &.{n}));
}

test "exists, not exists and count read correlated rows, and a LEFT JOIN miss binds NULLs" {
    const parent_cols = [_][]const u8{"id"};
    const child_cols = [_][]const u8{ "parent", "done" };
    const world: World = .{ .tables = &.{
        .{ .name = "parent", .columns = &parent_cols, .rows = &.{ &.{i(1)}, &.{i(2)} } },
        .{ .name = "child", .columns = &child_cols, .rows = &.{ &.{ i(1), i(1) }, &.{ i(1), n }, &.{ i(2), i(1) } } },
    } };
    const children = comptime rule.Select{ .table = "child", .alias = "c", .where = rule.eq(col("c", "parent"), col("p", "id")) };
    const open_child = comptime rule.Select{
        .table = "parent",
        .alias = "q",
        .joins = &.{.{ .table = "child", .alias = "c", .on = rule.eq(col("c", "parent"), col("q", "id")) }},
        .where = rule.all(&.{ rule.eq(col("q", "id"), col("p", "id")), rule.isNull(col("c", "done")) }),
    };
    const first = Scope.ofRow(world, "p", &parent_cols, &.{i(1)});
    const second = Scope.ofRow(world, "p", &parent_cols, &.{i(2)});
    try std.testing.expectEqual(i(2), try eval(&comptime rule.count(children), first));
    try std.testing.expectEqual(i(1), try eval(&comptime rule.count(children), second));
    try std.testing.expectEqual(i(1), try eval(&comptime rule.exists(open_child), first));
    try std.testing.expectEqual(i(0), try eval(&comptime rule.exists(open_child), second));
    try std.testing.expectEqual(i(1), try eval(&comptime rule.notExists(open_child), second));
}

test "an unknown column or table is an error, never a quiet false" {
    const cols = [_][]const u8{"a"};
    try std.testing.expectError(error.UnknownColumn, checks(comptime rule.eq(col("t", "zz"), int(1)), &cols, &.{i(1)}));
    const missing = comptime rule.Select{ .table = "nope", .alias = "x", .where = int(1) };
    try std.testing.expectError(error.UnknownTable, checks(comptime rule.exists(missing), &cols, &.{i(1)}));
}

test "between, in-list, length and the rsql macros follow SQL's answers for NULL" {
    const cols = [_][]const u8{ "n", "s" };
    const in_range = comptime rule.between(rule.field("n"), int(1), int(3));
    const listed = comptime rule.inList(rule.field("n"), &.{ int(1), int(2), rule.null_value });
    try std.testing.expectEqual(i(1), try evalRow(in_range, &cols, &.{ i(3), n }));
    try std.testing.expectEqual(i(0), try evalRow(in_range, &cols, &.{ i(4), n }));
    try std.testing.expectEqual(n, try evalRow(in_range, &cols, &.{ n, n }));
    try std.testing.expectEqual(i(1), try evalRow(listed, &cols, &.{ i(2), n }));
    // 5 is in no member, and a NULL member makes that unknown rather than false.
    try std.testing.expectEqual(n, try evalRow(listed, &cols, &.{ i(5), n }));
    const same = comptime rule.call("@same", &.{ rule.field("n"), rule.null_value });
    const distinct = comptime rule.call("@distinct", &.{ rule.field("s"), rule.text("x") });
    try std.testing.expectEqual(i(1), try evalRow(same, &cols, &.{ n, n }));
    try std.testing.expectEqual(i(0), try evalRow(same, &cols, &.{ i(1), n }));
    try std.testing.expectEqual(i(1), try evalRow(distinct, &cols, &.{ n, n }));
    try std.testing.expectEqual(i(0), try evalRow(distinct, &cols, &.{ n, .{ .text = "x" } }));
    const octets = comptime rule.eq(rule.call("@octets", &.{rule.field("s")}), int(2));
    try std.testing.expectEqual(i(1), try evalRow(octets, &cols, &.{ n, .{ .text = "\xc3\xa9" } }));
    const shape = comptime rule.all(&.{ rule.call("@initial", &.{ rule.field("s"), rule.text("a-z") }), rule.call("@charset", &.{ rule.field("s"), rule.text("a-z0-9") }) });
    try std.testing.expectEqual(i(1), try evalRow(shape, &cols, &.{ n, .{ .text = "ab1" } }));
    try std.testing.expectEqual(i(0), try evalRow(shape, &cols, &.{ n, .{ .text = "1ab" } }));
}

fn evalRow(comptime expr: Expr, columns: []const []const u8, row: []const Value) !Value {
    return eval(&expr, Scope.ofRow(.{}, "", columns, row));
}
