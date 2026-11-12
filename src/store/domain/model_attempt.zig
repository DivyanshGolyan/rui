//! Attempt timing persistence. Every attempt ends at resolution or retry
//! scheduling; that existing write saves its pair before live custody retires.
const std = @import("std");
const rsql = @import("../rsql.zig");

/// Replacement admission discards the preceding attempt's pair, even before
/// the replacement launches. New Operations already default both to NULL.
pub const replacement_sql = "latency_ms=NULL,first_event_ms=NULL";

const End = enum {
    resolution,
    retry,

    fn sql(comptime end: End) []const u8 {
        return switch (end) {
            .resolution => "resolved_at=@now,attempt_at=NULL,retry_scheduled_at=NULL",
            .retry => "attempt_at=NULL,retry_scheduled_at=@now",
        };
    }
};

/// The row owns the last ended attempt's pair. Live attempts snapshot the
/// common source; a backoff resolution preserves the pair already on the row.
const Spec = struct { end: End, set: []const u8, where: []const u8, Args: type, expect: rsql.Expect };

pub fn Write(comptime spec: Spec) type {
    const original = @typeInfo(spec.Args).@"struct";
    var names: [original.field_names.len + 2][:0]const u8 = undefined;
    var types: [original.field_names.len + 2]type = undefined;
    inline for (original.field_names, original.field_types, 0..) |name, Field, i| {
        names[i] = name;
        types[i] = Field;
    }
    names[original.field_names.len] = "latency_ms";
    names[original.field_names.len + 1] = "first_event_ms";
    types[original.field_names.len] = ?u64;
    types[original.field_names.len + 1] = ?u64;
    const Args = @Struct(.auto, null, &names, &types, &@splat(.{}));
    const query = rsql.Write(.{
        // Timings precede the phase transition: MySQL evaluates single-table
        // UPDATE assignments left-to-right, unlike SQLite's old-row reads.
        .sql = "UPDATE model_operation SET latency_ms=CASE WHEN attempt_at IS NOT NULL THEN ?" ++ std.fmt.comptimePrint("{d}", .{original.field_names.len + 1}) ++
            " ELSE latency_ms END,first_event_ms=CASE WHEN attempt_at IS NOT NULL THEN ?" ++ std.fmt.comptimePrint("{d}", .{original.field_names.len + 2}) ++
            " ELSE first_event_ms END," ++ spec.set ++ "," ++ spec.end.sql() ++ " WHERE " ++ spec.where,
        .Args = Args,
        .expect = spec.expect,
    });
    return struct {
        pub const sql = query.sql;
        pub fn queue(a: anytype, args: spec.Args) void {
            const timings = a.attemptTimings(args.operation_id);
            var values: Args = undefined;
            inline for (original.field_names) |name| @field(values, name) = @field(args, name);
            values.latency_ms = timings.latency_ms;
            values.first_event_ms = timings.first_event_ms;
            a.write(query, values);
        }
    };
}
