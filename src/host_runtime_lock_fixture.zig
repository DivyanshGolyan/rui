const std = @import("std");
const harness = @import("harness.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;
    const runtime = try harness.HostRuntime.open(init.io, allocator, args[1], .{});
    defer runtime.close() catch unreachable;
    try std.Io.File.stdout().writeStreamingAll(init.io, "ready\n");
    var byte: [1]u8 = undefined;
    _ = std.Io.File.stdin().readStreaming(init.io, &.{&byte}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
}
