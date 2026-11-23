const std = @import("std");
const core = @import("core_tools.zig");
const storage = @import("store.zig");

/// One `find_tools` call as read from its arguments. A refusal is settled without a search.
pub const Call = struct {
    words: core.FindTools = .{},
    refusal: ?[]const u8 = null,

    pub fn reloads(self: *const Call) bool {
        return self.refusal == null and self.words.reload;
    }
};

pub fn read(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput) !Call {
    if (input.arguments.length > core.find_tools_max_argument_bytes) return .{ .refusal = core.find_tools_too_long };
    const bytes = try arena.alloc(u8, @intCast(input.arguments.length));
    try store.readCoreArguments(input, bytes);
    var call: Call = .{};
    switch (try core.checkFindTools(arena, bytes, &call.words)) {
        .accepted => {},
        .rejected => |reason| call.refusal = reason,
    }
    return call;
}

/// Reads and settles a search call with no reload report. The Host settles a reload itself, with its report.
pub fn run(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, faults: storage.Faults) !void {
    const call = try read(store, arena, input);
    if (call.reloads()) return error.ReloadNeedsHost;
    try settle(store, input, &call, arena, faults);
}

/// Settles the call's one Tool Result. A reload's report is already in `call.words.report`.
pub fn settle(store: *storage.Store, input: *const storage.CoreActionInput, call: *const Call, arena: std.mem.Allocator, faults: storage.Faults) !void {
    _ = try store.findTools(input.binding, arena, &call.words, call.refusal, faults);
}
