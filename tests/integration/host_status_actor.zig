const std = @import("std");
const client = @import("client");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
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
