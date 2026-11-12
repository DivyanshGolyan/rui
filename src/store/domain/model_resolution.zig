//! The only model-resolution write constructor. Timing observations are
//! bound with the immutable resolution, never patched after its commit.
const std = @import("std");
const rsql = @import("../rsql.zig");

pub const now_sql = "resolved_at=@now,attempt_at=NULL,retry_scheduled_at=NULL";

/// `set` and `where` describe the outcome, not its timing policy. Every
/// resolving statement gets the same snapshot from the Store's live source.
const Spec = struct { set: []const u8, where: []const u8, Args: type, expect: rsql.Expect };

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
        .sql = "UPDATE model_operation SET " ++ spec.set ++ ",latency_ms=?" ++ std.fmt.comptimePrint("{d}", .{original.field_names.len + 1}) ++
            ",first_event_ms=?" ++ std.fmt.comptimePrint("{d}", .{original.field_names.len + 2}) ++ "," ++ now_sql ++ " WHERE " ++ spec.where,
        .Args = Args,
        .expect = spec.expect,
    });
    return struct {
        pub const sql = query.sql;
        pub fn queue(a: anytype, args: spec.Args) void {
            const timings = a.store.modelTimingSource().snapshot(args.operation_id, a.store.io);
            var values: Args = undefined;
            inline for (original.field_names) |name| @field(values, name) = @field(args, name);
            values.latency_ms = timings.latency_ms;
            values.first_event_ms = timings.first_event_ms;
            a.write(query, values);
        }
    };
}
