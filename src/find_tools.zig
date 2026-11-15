//! The model-facing tool loader validates arguments at execution time.
const std = @import("std");
const core = @import("core_tools.zig");
const storage = @import("store.zig");

pub fn run(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, faults: storage.Faults) !void {
    var words: core.FindTools = .{};
    // Refuse an oversized payload before reading it, as read_transcript does.
    const check: core.StartAgentCheck = checked: {
        const bytes = try arena.alloc(u8, @intCast(@min(input.arguments.length, core.find_tools_max_argument_bytes)));
        const arguments = (try store.readCoreToolArguments(input, bytes)) orelse break :checked .{ .rejected = core.find_tools_too_long };
        break :checked try core.checkFindTools(arena, arguments, &words);
    };
    _ = try store.findTools(input.binding, arena, &words, if (check == .rejected) check.rejected else null, faults);
}
