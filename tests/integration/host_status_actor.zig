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
    // `untimed STORE` reads time from a clock that never advances, so no
    // Host-info deadline expires and the status depends only on the bytes
    // the peer sends. A loaded runner can schedule a fixture's peer after
    // the real 1 s budget (#967); only probes of that budget run timed.
    const untimed = args.len == 3 and std.mem.eql(u8, args[1], "untimed");
    if (args.len != 2 and !untimed) return error.ExpectedStorePath;
    const Frozen = struct {
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .fromNanoseconds(0);
        }
    };
    const timed = std.Io.Threaded.global_single_threaded.io();
    var vtable = timed.vtable.*;
    vtable.now = Frozen.now;
    const io: std.Io = if (untimed) .{ .userdata = timed.userdata, .vtable = &vtable } else timed;
    const status = client.hostStatus(io, args[args.len - 1]);
    var buffer: [256]u8 = undefined;
    const line = switch (status) {
        .ready => |ready| try std.fmt.bufPrint(&buffer, "ready {s} {d} {s} {s} {d} {d}\n", .{
            std.fmt.bytesToHex(ready.instance, .lower),
            ready.active_capacity,
            if (ready.capabilities.bash) "true" else "false",
            @tagName(ready.capabilities.providers.codex),
            ready.started_at,
            ready.custody_occupied,
        }),
        else => try std.fmt.bufPrint(&buffer, "{s}\n", .{@tagName(status)}),
    };
    try std.Io.File.stdout().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), line);
}
