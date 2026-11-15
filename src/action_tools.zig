const std = @import("std");
const storage = @import("store.zig");
const args = @import("action_tool_args.zig");
const protocol = @import("protocol.zig");
const host_reply = @import("host_reply.zig");

pub fn run(store: *storage.Store, arena: std.mem.Allocator, input: *const storage.CoreActionInput, capacity: storage.ActionCapacityView, faults: storage.Faults) !void {
    const read = input.tool == .read_action;
    const bytes = try arena.alloc(u8, @intCast(@min(input.arguments.length, args.max_bytes)));
    const text = (try store.readCoreToolArguments(input, bytes)) orelse return refuse(store, input, faults);
    const request = args.parse(arena, text, read) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return refuse(store, input, faults),
    };
    if (!read) {
        var command: @import("command_input.zig").ActionControlCommand = .{ .session = input.session, .action_id = request.action };
        var key: [64]u8 = undefined;
        try command.key.set(try std.fmt.bufPrint(&key, @import("idempotency_key.zig").reserved_prefix ++ "action-stop/{d}", .{input.binding.action_id}));
        const result = try store.controlAction(.{ .core_stop = input.binding }, &command, capacity, faults);
        if (result == .infrastructure_failure) return error.CanonicalStoreFailure;
        return;
    }
    const buffer = try arena.alloc(u8, protocol.action_read_reply.max_bytes);
    var writer = std.Io.Writer.fixed(buffer);
    const json: protocol.JsonOut = .{ .writer = &writer };
    {
        const result = try arena.create(@import("action_read.zig").Read);
        store.readAction(&.{ .session = input.session, .action_id = request.action, .offset = request.offset }, result) catch |err| switch (err) {
            error.ActionNotFound, error.InvalidCursor => {
                _ = try store.failCoreCall(input.binding, if (err == error.ActionNotFound) "No such Action in your own Session." else "Invalid Action result byte cursor.", faults);
                return;
            },
            else => return err,
        };
        try host_reply.renderActionRead(json, result);
    }
    _ = try store.succeedCoreCall(input.binding, writer.buffered(), faults);
}

fn refuse(store: *storage.Store, input: *const storage.CoreActionInput, faults: storage.Faults) !void {
    _ = try store.failCoreCall(input.binding, "Expected action as a positive decimal string in your own Session; read_action alone also permits a decimal offset string. No Session selector is accepted.", faults);
}
