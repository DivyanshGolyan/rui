const std = @import("std");
const evaluator = @import("workflow_evaluator.zig");
const protocol = @import("workflow_protocol.zig");

pub fn main(init: std.process.Init) !void {
    // Prototype parent supplies only the three explicit stdio descriptors.
    applyProcessLimits() catch return error.ProcessLimitUnavailable;

    const input = try std.heap.page_allocator.alloc(u8, protocol.Limits.input_frame_bytes);
    // Mapping has process lifetime; do not touch all pages on exit.
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var input_length: usize = 0;
    while (input_length < input.len) {
        const read = try stdin_reader.interface.readSliceShort(input[input_length..]);
        if (read == 0) break;
        input_length += read;
    }
    if (input_length == input.len) {
        var probe: [1]u8 = undefined;
        if (try stdin_reader.interface.readSliceShort(&probe) != 0) {
            return error.InputFrameExceeded;
        }
    }

    const output = try std.heap.page_allocator.alloc(u8, protocol.Limits.output_frame_bytes);
    // Mapping has process lifetime; do not touch all pages on exit.
    const bridge = try std.heap.page_allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    // Mapping has process lifetime; do not touch all pages on exit.
    const result = evaluator.evaluate(input[0..input_length], output, bridge);
    if (result.len == 0) return error.OutputFrameExceeded;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.writeAll(result);
    try stdout_writer.interface.flush();
}

fn applyProcessLimits() !void {
    if (@import("builtin").os.tag == .windows) return;
    try std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 });
    try std.posix.setrlimit(.CPU, .{
        .cur = protocol.Limits.cpu_seconds,
        .max = protocol.Limits.cpu_seconds,
    });
    if (@hasField(std.posix.rlimit_resource, "AS")) {
        const limit = protocol.Limits.process_address_space_bytes;
        try std.posix.setrlimit(.AS, .{ .cur = limit, .max = limit });
    }
}
