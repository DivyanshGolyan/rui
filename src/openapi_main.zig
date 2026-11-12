//! Writes the wire contract (openapi.zig) to the path in its one argument.
const std = @import("std");
const openapi = @import("openapi.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    const document = try openapi.render(gpa);
    defer gpa.free(document);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = document });
}
