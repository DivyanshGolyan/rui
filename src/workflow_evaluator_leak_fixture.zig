const std = @import("std");
const evaluator = @import("workflow_evaluator.zig");
const protocol = @import("workflow_protocol.zig");

pub fn main(_: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const bridge = try allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer allocator.free(bridge);
    const output = try allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    defer allocator.free(output);

    var input_storage: [256]u8 = undefined;
    var input = protocol.Builder.init(&input_storage);
    try protocol.writeHeader(&input, protocol.request_magic);
    try input.writeString("export default async function workflow() { return { clean: true }; }");
    try input.writeByte(@intFromEnum(protocol.DataTag.null_value));
    try input.writeInt(u16, 0);

    for (0..64) |_| {
        const result = evaluator.evaluate(input.written(), output, bridge);
        var cursor = protocol.Cursor.init(result);
        try protocol.readHeader(&cursor, protocol.outcome_magic);
        if (try cursor.readByte() != @intFromEnum(protocol.OutcomeTag.completed)) {
            return error.EvaluationFailed;
        }
        _ = try cursor.skipValue(protocol.Limits.workflow_output_bytes);
        try cursor.finish();
    }
}
