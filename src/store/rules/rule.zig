//! A Store rule as a typed comptime value, and its one renderer to Rui SQL (the portable dialect statements are written in).
//! `eval.zig` reads the same value over plain rows. This file imports only `std`, so a rule joins no circle; `rsql.zig`
//! stays the only owner of how each engine spells the text this renders.
const std = @import("std");

/// One node of a rule. A column is named as `alias.name`; whether the name exists is the catalog's to check, not this file's.
/// An unknown column in a subquery over an empty table is therefore found only by that check, not by `eval.zig`.
pub const Expr = union(enum) {
    col: Col,
    int: i64,
    text: []const u8,
    null_value,
    cmp: Cmp,
    is_null: *const Expr,
    is_not_null: *const Expr,
    not: *const Expr,
    /// AND, left to right; at least one member.
    all: []const Expr,
    /// OR, left to right; at least one member.
    any: []const Expr,
    /// `value` equals one of `set`, written as the portable `IN (...)` for up to two members and an OR chain beyond.
    one_of: OneOf,
    coalesce: []const Expr,
    exists: *const Select,
    not_exists: *const Select,
    count: *const Select,

    pub const Col = struct { alias: []const u8, name: []const u8 };
    pub const Op = enum { eq, ne, lt, le, gt, ge };
    pub const Cmp = struct { op: Op, left: *const Expr, right: *const Expr };
    pub const OneOf = struct { value: *const Expr, set: []const []const u8 };
};

pub const Join = struct { table: []const u8, alias: []const u8, on: Expr };

/// `FROM table alias [LEFT JOIN ...] WHERE where`: the one query shape a rule can contain.
pub const Select = struct {
    table: []const u8,
    alias: []const u8,
    joins: []const Join = &.{},
    where: Expr,
};

pub fn col(comptime alias: []const u8, comptime name: []const u8) Expr {
    return .{ .col = .{ .alias = alias, .name = name } };
}
pub fn int(comptime value: i64) Expr {
    return .{ .int = value };
}
pub fn text(comptime value: []const u8) Expr {
    return .{ .text = value };
}
pub const null_value: Expr = .null_value;

fn compare(comptime op: Expr.Op, comptime left: Expr, comptime right: Expr) Expr {
    return .{ .cmp = .{ .op = op, .left = &left, .right = &right } };
}
pub fn eq(comptime left: Expr, comptime right: Expr) Expr {
    return compare(.eq, left, right);
}
pub fn ne(comptime left: Expr, comptime right: Expr) Expr {
    return compare(.ne, left, right);
}
pub fn lt(comptime left: Expr, comptime right: Expr) Expr {
    return compare(.lt, left, right);
}
pub fn le(comptime left: Expr, comptime right: Expr) Expr {
    return compare(.le, left, right);
}
pub fn gt(comptime left: Expr, comptime right: Expr) Expr {
    return compare(.gt, left, right);
}
pub fn ge(comptime left: Expr, comptime right: Expr) Expr {
    return compare(.ge, left, right);
}
pub fn isNull(comptime value: Expr) Expr {
    return .{ .is_null = &value };
}
pub fn isNotNull(comptime value: Expr) Expr {
    return .{ .is_not_null = &value };
}
pub fn not(comptime value: Expr) Expr {
    return .{ .not = &value };
}
pub fn all(comptime parts: []const Expr) Expr {
    return .{ .all = parts };
}
pub fn any(comptime parts: []const Expr) Expr {
    return .{ .any = parts };
}
pub fn oneOf(comptime value: Expr, comptime set: []const []const u8) Expr {
    return .{ .one_of = .{ .value = &value, .set = set } };
}
pub fn coalesce(comptime parts: []const Expr) Expr {
    return .{ .coalesce = parts };
}
pub fn exists(comptime query: Select) Expr {
    return .{ .exists = &query };
}
pub fn notExists(comptime query: Select) Expr {
    return .{ .not_exists = &query };
}
pub fn count(comptime query: Select) Expr {
    return .{ .count = &query };
}

fn symbol(op: Expr.Op) []const u8 {
    return switch (op) {
        .eq => "=",
        .ne => "<>",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
    };
}

/// The Rui SQL of a rule, with one canonical spacing: single spaces around keywords, none around operators.
/// A conjunction or disjunction nested in another list is parenthesised, so the text reads back as the value does.
pub fn render(comptime expr: Expr) []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        return switch (expr) {
            .col => |c| c.alias ++ "." ++ c.name,
            .int => |value| std.fmt.comptimePrint("{d}", .{value}),
            .text => |value| blk: {
                literalOk(value);
                break :blk "'" ++ value ++ "'";
            },
            .null_value => "NULL",
            .cmp => |c| operand(c.left.*) ++ symbol(c.op) ++ operand(c.right.*),
            .is_null => |value| operand(value.*) ++ " IS NULL",
            .is_not_null => |value| operand(value.*) ++ " IS NOT NULL",
            .not => |value| "NOT " ++ operand(value.*),
            .all => |parts| joined(parts, " AND "),
            .any => |parts| joined(parts, " OR "),
            .one_of => |s| oneOfText(s),
            .coalesce => |parts| "coalesce(" ++ joinedPlain(parts, ",") ++ ")",
            .exists => |query| "EXISTS(" ++ selectText("1", query.*) ++ ")",
            .not_exists => |query| "NOT EXISTS(" ++ selectText("1", query.*) ++ ")",
            .count => |query| "(" ++ selectText("count(*)", query.*) ++ ")",
        };
    }
}

/// An expression used as an operand of a comparison, a null test, `NOT`, `IN` or `BETWEEN`: everything that is not an
/// atom is parenthesised, so the text reads back with the structure the value has. This is the only place that decides it.
fn operand(comptime expr: Expr) []const u8 {
    return switch (expr) {
        .col, .int, .text, .null_value, .coalesce, .count, .exists => render(expr),
        .all, .any, .not, .cmp, .is_null, .is_not_null, .one_of, .not_exists => "(" ++ render(expr) ++ ")",
    };
}

fn joined(comptime parts: []const Expr, comptime separator: []const u8) []const u8 {
    comptime {
        if (parts.len == 0) @compileError("rule: a conjunction or disjunction needs a member");
        var out: []const u8 = "";
        for (parts, 0..) |part, index| {
            const nested = switch (part) {
                .any => std.mem.eql(u8, separator, " AND "),
                .all => std.mem.eql(u8, separator, " OR "),
                else => false,
            };
            out = out ++ (if (index == 0) "" else separator) ++ (if (nested) "(" ++ render(part) ++ ")" else render(part));
        }
        return out;
    }
}

fn joinedPlain(comptime parts: []const Expr, comptime separator: []const u8) []const u8 {
    comptime {
        if (parts.len == 0) @compileError("rule: a coalesce needs a member");
        var out: []const u8 = "";
        for (parts, 0..) |part, index| out = out ++ (if (index == 0) "" else separator) ++ render(part);
        return out;
    }
}

fn oneOfText(comptime s: Expr.OneOf) []const u8 {
    comptime {
        if (s.set.len == 0) @compileError("rule: a set needs a member");
        for (s.set) |member| literalOk(member);
        const subject = operand(s.value.*);
        var out: []const u8 = "";
        if (s.set.len <= 2) {
            for (s.set, 0..) |member, index| out = out ++ (if (index == 0) "" else ",") ++ "'" ++ member ++ "'";
            return subject ++ " IN (" ++ out ++ ")";
        }
        for (s.set, 0..) |member, index| out = out ++ (if (index == 0) "" else " OR ") ++ subject ++ "='" ++ member ++ "'";
        return "(" ++ out ++ ")";
    }
}

/// A text literal is spliced between quotes, so it holds none.
fn literalOk(comptime value: []const u8) void {
    if (std.mem.indexOfScalar(u8, value, '\'') != null) @compileError("rule: a text literal holds no quote: " ++ value);
}

fn identifierOk(comptime name: []const u8) void {
    if (name.len == 0) @compileError("rule: an empty name");
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') @compileError("rule: a name is letters, digits and underscores: " ++ name);
}

fn selectText(comptime projection: []const u8, comptime query: Select) []const u8 {
    comptime {
        identifierOk(query.table);
        identifierOk(query.alias);
        var out: []const u8 = "SELECT " ++ projection ++ " FROM " ++ query.table ++ " " ++ query.alias;
        for (query.joins) |join| {
            identifierOk(join.table);
            identifierOk(join.alias);
            out = out ++ " LEFT JOIN " ++ join.table ++ " " ++ join.alias ++ " ON " ++ render(join.on);
        }
        return out ++ " WHERE " ++ render(query.where);
    }
}

test "a comparison, a null test and a set render as portable Rui SQL" {
    try std.testing.expectEqualStrings("t.a=1 AND t.b IS NULL AND t.c IN ('x','y')", comptime render(all(&.{
        eq(col("t", "a"), int(1)),
        isNull(col("t", "b")),
        oneOf(col("t", "c"), &.{ "x", "y" }),
    })));
    try std.testing.expectEqualStrings("(t.c='x' OR t.c='y' OR t.c='z')", comptime render(oneOf(col("t", "c"), &.{ "x", "y", "z" })));
}

test "SH-181 a disjunction inside a conjunction keeps its parentheses, and a negation binds its whole operand" {
    try std.testing.expectEqualStrings("t.a=1 AND (t.b=2 OR t.c=3)", comptime render(all(&.{
        eq(col("t", "a"), int(1)),
        any(&.{ eq(col("t", "b"), int(2)), eq(col("t", "c"), int(3)) }),
    })));
    try std.testing.expectEqualStrings("NOT (t.a=1 AND t.b=2)", comptime render(not(all(&.{ eq(col("t", "a"), int(1)), eq(col("t", "b"), int(2)) }))));
}

test "a boolean comparison renders both sides in parentheses" {
    try std.testing.expectEqualStrings("(t.a IS NULL)=(t.b IS NULL)", comptime render(eq(isNull(col("t", "a")), isNull(col("t", "b")))));
}

test "SH-181 every node kind used as an operand keeps its own structure" {
    const q = comptime Select{ .table = "c", .alias = "c", .where = eq(col("c", "p"), col("p", "id")) };
    const x = comptime col("t", "a");
    try std.testing.expectEqualStrings("(NOT EXISTS(SELECT 1 FROM c c WHERE c.p=p.id))=1", comptime render(eq(notExists(q), int(1))));
    try std.testing.expectEqualStrings("(NOT EXISTS(SELECT 1 FROM c c WHERE c.p=p.id)) IS NULL", comptime render(isNull(notExists(q))));
    try std.testing.expectEqualStrings("(t.a IS NULL) IN ('x')", comptime render(oneOf(isNull(x), &.{"x"})));
    try std.testing.expectEqualStrings("((t.a=1 AND t.a=2)='x' OR (t.a=1 AND t.a=2)='y' OR (t.a=1 AND t.a=2)='z')", comptime render(oneOf(all(&.{ eq(x, int(1)), eq(x, int(2)) }), &.{ "x", "y", "z" })));
    try std.testing.expectEqualStrings("(t.a=1)=(t.a=2)", comptime render(eq(eq(x, int(1)), eq(x, int(2)))));
}
