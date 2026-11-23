const std = @import("std");
const core = @import("core_tools.zig");
const relist = @import("server_mcp_relist.zig").Relist;
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

/// Writes a reload's report: the MCP servers asked to list again, or that none is configured. The lists land later,
/// so the report names no tools; a later search finds them.
pub fn writeReload(out: *std.Io.Writer, asked: []const relist.Asked) !void {
    if (asked.len == 0) return out.writeAll("No MCP servers are configured, so nothing was reloaded.");
    try out.print("Asked {d} MCP server{s} to list {s} tools again: ", .{ asked.len, if (asked.len == 1) "" else "s", if (asked.len == 1) "its" else "their" });
    for (asked, 0..) |each, index| {
        if (index != 0) try out.writeAll(", ");
        try out.writeAll(each.server);
    }
    if (asked.len == 1) {
        try out.writeAll(". Its new tools can be found with find_tools once its list lands, usually within a few seconds.");
    } else {
        try out.writeAll(". Each server's new tools can be found with find_tools once its list lands, usually within a few seconds.");
    }
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
