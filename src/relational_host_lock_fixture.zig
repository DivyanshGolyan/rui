const std = @import("std");
const store_module = @import("host_store.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len != 2) return error.InvalidArguments;
    var store = try store_module.Store.open(args[1]);
    defer store.close();
    try std.Io.File.stdout().writeStreamingAll(init.io, "ready\n");
    var byte: [1]u8 = undefined;
    _ = std.Io.File.stdin().readStreaming(init.io, &.{&byte}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
}
