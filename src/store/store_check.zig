//! The read-only statements that count the rows of a Store which break a rule the schema holds.
//!
//! One statement per rule and per reference, rendered from the one schema value, so the plain form's missing CHECKs
//! and FOREIGN KEYs are still checked by the same text the strict form enforces. Each statement returns one number:
//! the rows that violate it. A NULL makes a rule unknown, and an unknown rule is not a violation, as in a CHECK and
//! in a FOREIGN KEY with a NULL part.
const std = @import("std");
const schema = @import("schema.zig");
const rsql = @import("rsql.zig");

pub const Kind = enum { column_rule, table_rule, reference };

pub const Check = struct {
    kind: Kind,
    table: []const u8,
    /// `table.column` for a column rule, `table#N` for the Nth cross-column rule, `table(columns)->parent` for a reference.
    name: []const u8,
    /// `SELECT COUNT(*) ...`: the number of violating rows.
    sql: [:0]const u8,
};

/// Every check of one engine's tables, in the catalog's order: each table's column rules, then its cross-column rules,
/// then its references.
pub fn checks(comptime dialect: rsql.Dialect) []const Check {
    return comptime blk: {
        @setEvalBranchQuota(100_000_000);
        var result: []const Check = &.{};
        for (schema.tables) |table| {
            if (!table.engines.on(dialect)) continue;
            for (table.columns) |column| {
                if (!column.engines.on(dialect)) continue;
                const rule = schema.columnRuleSql(dialect, table.name, column) orelse continue;
                result = result ++ .{violators(.column_rule, table.name, table.name ++ "." ++ column.name, "NOT (" ++ rule ++ ")")};
            }
            for (schema.tableRuleSql(dialect, table.name), 0..) |rule, position| {
                result = result ++ .{violators(.table_rule, table.name, std.fmt.comptimePrint("{s}#{d}", .{ table.name, position }), "NOT (" ++ rule ++ ")")};
            }
            for (table.foreign_keys) |key| {
                if (!parentOn(dialect, key.references)) continue;
                result = result ++ .{reference(table.name, key)};
            }
        }
        break :blk result;
    };
}

fn violators(comptime kind: Kind, comptime table: []const u8, comptime name: []const u8, comptime condition: []const u8) Check {
    return .{ .kind = kind, .table = table, .name = name, .sql = "SELECT COUNT(*) FROM " ++ table ++ " WHERE " ++ condition };
}

fn parentOn(comptime dialect: rsql.Dialect, comptime name: []const u8) bool {
    for (schema.tables) |table| if (std.mem.eql(u8, table.name, name)) return table.engines.on(dialect);
    return false;
}

/// A row whose reference columns are all set and name no row of the referenced table.
fn reference(comptime table: []const u8, comptime key: schema.ForeignKey) Check {
    var set: []const u8 = "";
    var same: []const u8 = "";
    var named: []const u8 = "";
    for (key.columns, key.referenced, 0..) |column, target, position| {
        const joiner = if (position == 0) "" else " AND ";
        set = set ++ joiner ++ "c." ++ column ++ " IS NOT NULL";
        same = same ++ joiner ++ "p." ++ target ++ "=c." ++ column;
        named = named ++ (if (position == 0) "" else ",") ++ column;
    }
    return .{
        .kind = .reference,
        .table = table,
        .name = table ++ "(" ++ named ++ ")->" ++ key.references,
        .sql = "SELECT COUNT(*) FROM " ++ table ++ " c WHERE " ++ set ++ " AND NOT EXISTS (SELECT 1 FROM " ++ key.references ++ " p WHERE " ++ same ++ ")",
    };
}
