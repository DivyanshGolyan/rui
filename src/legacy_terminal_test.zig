//! Build-only caller for the retained single-prompt terminal owner. This is
//! not installed and adds no public production route or terminal policy.
const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    defer std.heap.c_allocator.free(args);
    if (args.len > 1 and std.mem.eql(u8, args[1], "session")) {
        try cli.enterSessionLegacy(init, args[2..]);
        return 0;
    }
    return cli.main(init);
}
