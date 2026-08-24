const std = @import("std");
const core_contract = @import("core_contract.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;

    const wasm = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(1024 * 1024),
    );
    defer allocator.free(wasm);
    try core_contract.verify(wasm);
}
