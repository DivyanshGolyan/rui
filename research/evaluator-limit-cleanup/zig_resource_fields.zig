const std = @import("std");
pub fn main() void {
    std.debug.print("has_AS={}; has_RSS={}\n", .{ @hasField(std.posix.rlimit_resource, "AS"), @hasField(std.posix.rlimit_resource, "RSS") });
}
