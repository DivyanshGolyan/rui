//! What a column's own value rules accept. `schema.Column` owns each rule once: it renders the CHECK a test database
//! enforces and `accepts` evaluates the same value, so the two cannot disagree; `engine.bind` calls it before a statement is sent.
const std = @import("std");
const char_set = @import("rules/char_set.zig");
const row_rules = @import("rules/row.zig");

/// A bound value as a rule sees it.
pub const Value = union(enum) { null, int: i64, octets: []const u8 };

/// Whether `value` satisfies every rule `column` carries by itself.
/// `column` is a `schema.Column`, taken by shape so this file imports nothing and joins no circle.
pub fn accepts(comptime column: anytype, value: Value) bool {
    if (value == .null) return column.nullable;
    switch (column.type) {
        .int => {
            if (value != .int) return false;
        },
        .flag => {
            if (value != .int or value.int < 0 or value.int > 1) return false;
        },
        .text, .bytes => |octets| {
            if (value != .octets) return false;
            if (octets) |bounds| if (!within(value.octets.len, bounds)) return false;
        },
        .tag => |values| {
            if (value != .octets) return false;
            if (!oneOf(values, value.octets)) return false;
        },
    }
    if (column.range) |range| {
        if (value != .int) return false;
        if (value.int < range.min) return false;
        if (range.max) |max| if (value.int > max) return false;
    }
    if (column.initial) |set| if (value != .octets or value.octets.len == 0 or !char_set.inSet(set, value.octets[0])) return false;
    if (column.charset) |set| {
        if (value != .octets) return false;
        for (value.octets) |byte| if (!char_set.inSet(set, byte)) return false;
    }
    return true;
}

fn within(length: usize, bounds: anytype) bool {
    return length >= bounds.min and length <= bounds.max;
}

fn oneOf(values: []const []const u8, text: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, text)) return true;
    return false;
}

/// Whether the row a statement inserts satisfies every CHECK rule of `table` whose columns it binds: `names` are the bound columns and
/// `values` their values in the same order (null for one the caller cannot state). The rule value that renders each CHECK is evaluated here,
/// so the Host answers before the engine is asked. A rule that reads a column the statement does not bind is left to the engine's own CHECK.
/// `table` is a `schema.Table`, taken by shape like `accepts` takes a column.
pub fn acceptsRow(comptime table: anytype, comptime names: []const []const u8, values: []const ?Value) bool {
    inline for (table.checks) |check| if (!row_rules.accepts(check, names, values)) return false;
    inline for (table.columns) |column| if (comptime column.check) |check| if (!row_rules.accepts(check, names, values)) return false;
    return true;
}
