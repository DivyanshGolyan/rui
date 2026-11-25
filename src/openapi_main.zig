const std = @import("std");
const openapi = @import("openapi.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.Usage;
    const document = try openapi.render(gpa);
    defer gpa.free(document);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = document });
    const rejections = try openapi.renderRejections(gpa);
    defer gpa.free(rejections);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = rejections });
    const environment = try openapi.renderHostEnvironment(gpa);
    defer gpa.free(environment);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[3], .data = environment });
    const endings = try openapi.renderTurnEndings(gpa);
    defer gpa.free(endings);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[4], .data = endings });
}
