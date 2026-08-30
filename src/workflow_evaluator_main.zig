const std = @import("std");
const evaluator = @import("workflow_evaluator.zig");
const protocol = @import("workflow_protocol.zig");

pub fn main(init: std.process.Init) !void {
    try closeUnintendedDescriptors();
    applyProcessLimits() catch return error.ProcessLimitUnavailable;

    const input = try std.heap.page_allocator.alloc(u8, protocol.Limits.input_frame_bytes);
    defer {
        @memset(input, 0);
        std.heap.page_allocator.free(input);
    }
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
    defer {
        @memset(output, 0);
        std.heap.page_allocator.free(output);
    }
    const bridge = try std.heap.page_allocator.alloc(u8, protocol.Limits.bridge_arena_bytes);
    defer {
        @memset(bridge, 0);
        std.heap.page_allocator.free(bridge);
    }
    const result = evaluator.evaluate(input[0..input_length], output, bridge);
    if (result.len == 0) return error.OutputFrameExceeded;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    try stdout_writer.interface.writeAll(result);
    try stdout_writer.interface.flush();
}

fn closeUnintendedDescriptors() !void {
    if (@import("builtin").os.tag == .windows) return;

    const descriptor_limit = try std.posix.getrlimit(.NOFILE);
    const upper_bound: std.posix.rlim_t = @min(
        descriptor_limit.cur,
        @as(std.posix.rlim_t, std.math.maxInt(std.posix.fd_t)),
    );
    var descriptor: std.posix.fd_t = 3;
    while (@as(std.posix.rlim_t, @intCast(descriptor)) < upper_bound) : (descriptor += 1) {
        while (true) switch (std.posix.errno(std.posix.system.close(descriptor))) {
            .SUCCESS, .BADF => break,
            .INTR => continue,
            else => return error.DescriptorIsolationUnavailable,
        };
    }
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
