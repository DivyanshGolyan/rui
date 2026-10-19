const std = @import("std");
const boundary = @import("boundary");

pub fn main() void {
    const ordinary = "const std = @import(\"std\"); test { std.debug.print(\"ok\", .{}); }";
    const nested = "const std = @import(\"std\"); test { const S = struct { test {} }; _ = S; std.debug.print(\"ok\", .{}); }";
    std.debug.print("ordinary diagnostic accepted: {}\nnested diagnostic accepted: {}\n", .{
        boundary.check(ordinary, &.{}) == null,
        boundary.check(nested, &.{}) == null,
    });
}
