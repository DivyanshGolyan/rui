//! A rule value answered over the one row a statement inserts. `column_rules.acceptsRow` calls `accepts`; the columns a rule reads
//! are found at compile time, so a statement that binds too few of them pays nothing at run time.
const std = @import("std");
const rule = @import("rule.zig");
const evaluator = @import("eval.zig");

/// Whether a row satisfies a row-local `rule_value` over a row whose columns are `bound`, with `values` in the same order, each null or a union
/// with `null`, `int` and `octets` cases (the shape a bound value has); true when the rule reads a column that is not bound or has no value,
/// since such a rule is left to the engine's own CHECK. A null value in `values` is one the caller cannot state. A rule the evaluator cannot answer is refused.
pub inline fn accepts(comptime rule_value: anytype, comptime bound: []const []const u8, values: anytype) bool {
    const names = comptime reads(rule_value);
    var row: [names.len]evaluator.Value = undefined;
    inline for (names, 0..) |name, at| {
        const position = comptime positionOf(bound, name) orelse return true;
        row[at] = switch (values[position] orelse return true) {
            .null => .null,
            .int => |number| .{ .int = number },
            .octets => |bytes| .{ .text = bytes },
        };
    }
    const answer = evaluator.eval(&rule_value, evaluator.Scope.ofRow(.{}, "", names, &row)) catch return false;
    return answer != .int or answer.int != 0;
}

fn positionOf(comptime bound: []const []const u8, comptime name: []const u8) ?usize {
    for (bound, 0..) |candidate, at| if (std.mem.eql(u8, candidate, name)) return at;
    return null;
}

/// The columns a row-local rule reads, each once, in first-read order. A rule over other tables (a subquery) has none to name:
/// it is refused at compile time, since a row alone cannot answer it.
fn reads(comptime expr: anytype) []const []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var names: []const []const u8 = &.{};
        collect(expr, &names);
        return names;
    }
}

fn collect(comptime expr: anytype, comptime names: *[]const []const u8) void {
    switch (expr) {
        .col => |c| {
            if (c.alias.len != 0) @compileError("rule: " ++ c.alias ++ "." ++ c.name ++ " is not a column of the checked row");
            for (names.*) |seen| if (std.mem.eql(u8, seen, c.name)) return;
            names.* = names.* ++ &[_][]const u8{c.name};
        },
        .int, .text, .null_value => {},
        .cmp => |c| {
            collect(c.left.*, names);
            collect(c.right.*, names);
        },
        .is_null, .is_not_null, .not, .group => |inner| collect(inner.*, names),
        .all, .any, .coalesce => |parts| for (parts) |part| collect(part, names),
        .one_of => |s| collect(s.value.*, names),
        .between => |b| {
            collect(b.value.*, names);
            collect(b.low.*, names);
            collect(b.high.*, names);
        },
        .in_list => |l| {
            collect(l.value.*, names);
            for (l.items) |item| collect(item, names);
        },
        .call => |c| for (c.args) |arg| collect(arg, names),
        .exists, .not_exists, .count => @compileError("rule: a subquery reads other rows, not one checked row"),
    }
}

test "SH-180 the columns a row-local rule reads are named once each, in first-read order" {
    const probe = comptime rule.any(&.{ rule.compare(.eq, rule.field("a"), rule.field("b")), rule.between(rule.field("a"), rule.literal(1), rule.field("c")), rule.call(.same, &.{ rule.field("b"), rule.literal("x") }) });
    const names = comptime reads(probe);
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings("a", names[0]);
    try std.testing.expectEqualStrings("b", names[1]);
    try std.testing.expectEqualStrings("c", names[2]);
}
