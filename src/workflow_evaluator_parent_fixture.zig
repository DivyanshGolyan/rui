const std = @import("std");
const parent = @import("workflow_evaluator_parent.zig");
const protocol = @import("workflow_protocol.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const arguments = try init.minimal.args.toSlice(allocator);
    defer allocator.free(arguments);
    if (arguments.len != 3) return error.InvalidArguments;

    var request_storage: [512]u8 = undefined;
    var request = protocol.Builder.init(&request_storage);
    try protocol.writeHeader(&request, protocol.request_magic);
    try request.writeString(
        "export default async function workflow() { return typeof globalThis.process; }",
    );
    try request.writeByte(@intFromEnum(protocol.DataTag.null_value));
    try request.writeInt(u16, 0);

    const output = try allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer allocator.free(output);
    const result = try parent.run(
        init.io,
        allocator,
        arguments[1],
        request.written(),
        output,
        protocol.Limits.wall_milliseconds + 1_000,
    );
    if (result.peak_rss_bytes) |peak_rss| {
        if (peak_rss > protocol.Limits.process_address_space_bytes) {
            return error.ProcessMemoryLimitExceeded;
        }
    }
    var cursor = protocol.Cursor.init(result.output);
    try protocol.readHeader(&cursor, protocol.outcome_magic);
    if (try cursor.readByte() != @intFromEnum(protocol.OutcomeTag.completed)) {
        return error.UnexpectedOutcome;
    }
    if (try cursor.readByte() != @intFromEnum(protocol.DataTag.string) or
        !std.mem.eql(u8, try cursor.readString(32), "undefined"))
    {
        return error.EnvironmentLeaked;
    }
    try cursor.finish();

    request.index = 0;
    try protocol.writeHeader(&request, protocol.request_magic);
    try request.writeString(
        "export default async function workflow() { while (true) {} }",
    );
    try request.writeByte(@intFromEnum(protocol.DataTag.null_value));
    try request.writeInt(u16, 0);
    var deadline_enforced = false;
    _ = parent.run(
        init.io,
        allocator,
        arguments[1],
        request.written(),
        output,
        100,
    ) catch |err| switch (err) {
        error.DeadlineExceeded => {
            deadline_enforced = true;
        },
        else => return err,
    };
    if (!deadline_enforced) return error.OuterDeadlineNotEnforced;

    var abnormal_classified = false;
    _ = parent.run(
        init.io,
        allocator,
        arguments[2],
        request.written(),
        output,
        1_000,
    ) catch |err| switch (err) {
        error.AbnormalExit => {
            abnormal_classified = true;
        },
        else => return err,
    };
    if (!abnormal_classified) return error.AbnormalExitWasTrusted;

    const terminations = [_]struct { input: u8, expected: anyerror }{
        .{ .input = 0xfc, .expected = error.CpuLimitExceeded },
        .{ .input = 0xfd, .expected = error.ChildCrashed },
        .{ .input = 0xfe, .expected = error.ChildKilled },
    };
    for (terminations) |termination| {
        var classified = false;
        _ = parent.run(
            init.io,
            allocator,
            arguments[2],
            &.{termination.input},
            output,
            1_000,
        ) catch |err| {
            if (err == termination.expected) {
                classified = true;
            } else {
                return err;
            }
        };
        if (!classified) return error.TerminationWasTrusted;
    }

    const oversized_input = try allocator.alloc(u8, protocol.Limits.input_frame_bytes + 1);
    defer allocator.free(oversized_input);
    var input_overflow_classified = false;
    _ = parent.run(
        init.io,
        allocator,
        arguments[2],
        oversized_input,
        output,
        1_000,
    ) catch |err| switch (err) {
        error.InputFrameExceeded => input_overflow_classified = true,
        else => return err,
    };
    if (!input_overflow_classified) return error.InputOverflowWasTrusted;

    var short_output: [protocol.Limits.output_frame_bytes - 1]u8 = undefined;
    var output_overflow_classified = false;
    _ = parent.run(
        init.io,
        allocator,
        arguments[2],
        &.{},
        &short_output,
        1_000,
    ) catch |err| switch (err) {
        error.OutputFrameExceeded => output_overflow_classified = true,
        else => return err,
    };
    if (!output_overflow_classified) return error.OutputOverflowWasTrusted;

    var closed_pipes_deadline = false;
    _ = parent.run(
        init.io,
        allocator,
        arguments[2],
        &.{0xff},
        output,
        100,
    ) catch |err| switch (err) {
        error.DeadlineExceeded => {
            closed_pipes_deadline = true;
        },
        else => return err,
    };
    if (!closed_pipes_deadline) return error.ClosedPipesEvadedDeadline;
}
