//! The model-facing tool loader validates arguments at execution time.
const std = @import("std");
const core = @import("core_tools.zig");
const storage = @import("store.zig");

pub fn run(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, faults: storage.Faults) !void {
    var words: core.FindTools = .{};
    // Refuse an oversized payload before reading it, as read_transcript does.
    const check: core.StartAgentCheck = if (input.arguments.length > core.find_tools_max_argument_bytes)
        .{ .rejected = core.find_tools_too_long }
    else check: {
        const bytes = try arena.alloc(u8, @intCast(input.arguments.length));
        try store.readCoreArguments(input, bytes);
        break :check try core.checkFindTools(arena, bytes, &words);
    };
    _ = try store.findTools(input.binding, arena, &words, if (check == .rejected) check.rejected else null, faults);
}
