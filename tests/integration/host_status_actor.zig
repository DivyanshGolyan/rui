const std = @import("std");
const client = @import("client");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len == 4 or args.len == 5) {
        if (!std.mem.eql(u8, args[1], "stop")) return error.ExpectedStop;
        if (args[3].len != 32) return error.InvalidInstanceId;
        var instance: [16]u8 = undefined;
        _ = try std.fmt.hexToBytes(&instance, args[3]);
        var reply: client.ReplyBuffer = .{};
        const result = client.stopHost(std.Io.Threaded.global_single_threaded.io(), .{
            .store = args[2],
            .instance = instance,
            .drop_reply = if (args.len == 5) args[4] else null,
        }, &reply) catch |err| {
            try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), @errorName(err));
            return;
        };
        try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), @tagName(result));
        return;
    }
    if (args.len != 2) return error.ExpectedStorePath;
    const status = client.hostStatus(std.Io.Threaded.global_single_threaded.io(), args[1]);
    var buffer: [256]u8 = undefined;
    const line = switch (status) {
        .ready => |ready| try std.fmt.bufPrint(&buffer, "ready {s} {d} {s} {s} {s}\n", .{
            std.fmt.bytesToHex(ready.instance, .lower),
            ready.active_capacity,
            if (ready.capabilities.bash) "true" else "false",
            if (ready.capabilities.model) "true" else "false",
            if (ready.capabilities.managed_authentication) "true" else "false",
        }),
        else => try std.fmt.bufPrint(&buffer, "{s}\n", .{@tagName(status)}),
    };
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), line);
}
