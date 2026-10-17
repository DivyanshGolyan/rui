//! Native adapter actor: no Host, frontend or syscall interposition.
const std = @import("std");
const Terminal = @import("terminal");

pub fn main() !void {
    const flags = std.c.fcntl(1, std.c.F.GETFL);
    if (flags < 0) return error.TerminalCleanupFailed;
    var terminal: Terminal = .{
        .original = undefined,
        .flags = .{ 0, flags },
        .colour = false,
        .active = false,
    };
    try terminal.detached("/tmp/a' path", "--session", null);
}
