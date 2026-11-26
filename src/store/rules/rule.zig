//! A Store rule as a typed comptime value, and its one renderer to Rui SQL (the portable dialect statements are written in).
//! `eval.zig` reads the same value over plain rows. This file imports only `std`, so a rule joins no circle; `rsql.zig`
//! stays the only owner of how each engine spells the text this renders.
const std = @import("std");

/// One node of a rule. A column is named as `alias.name`; whether the name exists is the catalog's to check, not this file's.
pub const Expr = union(enum) {
    col: Col,
    int: i64,
    text: []const u8,
    null_value,
    cmp: Cmp,
    is_null: *const Expr,
    is_not_null: *const Expr,
    not: *const Expr,
    /// AND, left to right; an empty list is true.
    all: []const Expr,
    /// OR, left to right; an empty list is false.
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
            .text => |value| "'" ++ value ++ "'",
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

/// An expression used as an operand of `=`, `IS NULL` or `NOT`: a connective needs parentheses there.
fn operand(comptime expr: Expr) []const u8 {
    return switch (expr) {
        .all, .any, .not, .cmp, .is_null, .is_not_null => "(" ++ render(expr) ++ ")",
        .one_of => |s| if (s.set.len <= 2) "(" ++ render(expr) ++ ")" else render(expr),
        else => render(expr),
    };
}

fn joined(comptime parts: []const Expr, comptime separator: []const u8) []const u8 {
    comptime {
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
        var out: []const u8 = "";
        for (parts, 0..) |part, index| out = out ++ (if (index == 0) "" else separator) ++ render(part);
        return out;
    }
}

fn oneOfText(comptime s: Expr.OneOf) []const u8 {
    comptime {
        const subject = render(s.value.*);
        var out: []const u8 = "";
        if (s.set.len <= 2) {
            for (s.set, 0..) |member, index| out = out ++ (if (index == 0) "" else ",") ++ "'" ++ member ++ "'";
            return subject ++ " IN (" ++ out ++ ")";
        }
        for (s.set, 0..) |member, index| out = out ++ (if (index == 0) "" else " OR ") ++ subject ++ "='" ++ member ++ "'";
        return "(" ++ out ++ ")";
    }
}

fn selectText(comptime projection: []const u8, comptime query: Select) []const u8 {
    comptime {
        var out: []const u8 = "SELECT " ++ projection ++ " FROM " ++ query.table ++ " " ++ query.alias;
        for (query.joins) |join| out = out ++ " LEFT JOIN " ++ join.table ++ " " ++ join.alias ++ " ON " ++ render(join.on);
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

test "a disjunction inside a conjunction keeps its parentheses, and a negation binds its whole operand" {
    try std.testing.expectEqualStrings("t.a=1 AND (t.b=2 OR t.c=3)", comptime render(all(&.{
        eq(col("t", "a"), int(1)),
        any(&.{ eq(col("t", "b"), int(2)), eq(col("t", "c"), int(3)) }),
    })));
    try std.testing.expectEqualStrings("NOT (t.a=1 AND t.b=2)", comptime render(not(all(&.{ eq(col("t", "a"), int(1)), eq(col("t", "b"), int(2)) }))));
}

test "a boolean comparison renders both sides in parentheses" {
    try std.testing.expectEqualStrings("(t.a IS NULL)=(t.b IS NULL)", comptime render(eq(isNull(col("t", "a")), isNull(col("t", "b")))));
}
