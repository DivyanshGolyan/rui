//! Stack overflow witness for signal_stack.zig: the main thread and a spawned
//! thread each overflow in a child process, which must die with a segfault
//! trace printed from the alternate stack. Without one, the kernel kills the
//! child silently because the handler cannot run on the exhausted stack.
const std = @import("std");
const signal_stack = @import("signal_stack.zig");

// As in cli.zig: Zig reserves no signal stack, so only signal_stack.zig can.
pub const std_options: std.Options = .{ .signal_stack_size = null };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "main")) {
        try signal_stack.attachMain();
        overflow(0);
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "thread")) {
        const thread = try signal_stack.spawn(.{ .stack_size = 1 << 20 }, overflow, .{0});
        thread.join();
    }
    if (args.len != 1) return error.InvalidArguments;
    const self = try std.process.executablePathAlloc(init.io, arena);
    for ([_][]const u8{ "main", "thread" }) |case| {
        const result = try std.process.run(arena, init.io, .{ .argv = &.{ self, case } });
        if (result.term != .signal or result.term.signal != .ABRT or
            std.mem.indexOf(u8, result.stderr, "Segmentation fault at address") == null or
            std.mem.indexOf(u8, result.stderr, "in overflow") == null)
        {
            std.debug.print("{s}: no stack overflow trace ({any})\n{s}\n", .{ case, result.term, result.stderr });
            return error.MissingStackOverflowTrace;
        }
    }
}

fn overflow(depth: usize) void {
    // Under one page, so no stack probe frame (which has no unwind table) is on top.
    var frame: [2048]u8 = undefined;
    frame[depth % frame.len] = @truncate(depth);
    std.mem.doNotOptimizeAway(&frame);
    overflow(depth + 1);
    std.mem.doNotOptimizeAway(frame[0]);
}
