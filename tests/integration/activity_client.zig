const std = @import("std");
const client = @import("rui_client");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    defer std.heap.c_allocator.free(args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "layout")) {
        var buffer: [128]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&buffer, "activity page={d} cursor={d} bytes (fixed owned values)\n", .{ @sizeOf(client.protocol_reply.ActivityPage), @sizeOf(client.protocol_reply.ActivityCursor) }));
        return;
    }
    const requests: client.Requests = .{ .io = init.io };
    if (args.len == 8 and std.mem.eql(u8, args[1], "page")) {
        const reply = try requests.activityPage(args[2], args[3], .{
            .end = if (std.mem.eql(u8, args[4], "null")) null else try std.fmt.parseInt(u64, args[4], 10),
            .position = try std.fmt.parseInt(u64, args[5], 10),
            .ordinal = if (std.mem.eql(u8, args[6], "null")) null else try std.fmt.parseInt(u64, args[6], 10),
            .direction = std.meta.stringToEnum(@FieldType(client.protocol_reply.ActivityCursor, "direction"), args[7]) orelse return error.InvalidArguments,
        });
        const page = switch (reply) {
            .page => |page| page,
            .failure => return error.ActivityUnavailable,
        };
        var buffer: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(init.io, &buffer);
        try out.interface.writeAll("{\"page\":");
        try page.facts.writeJson(&out.interface);
        try out.interface.writeAll(",\"next\":");
        try std.json.Stringify.value(page.continuation(), .{}, &out.interface);
        try out.interface.writeByte('}');
        try out.interface.flush();
    } else if (args.len == 6 and std.mem.eql(u8, args[1], "content")) {
        if (try requests.readActivityContent(args[2], args[3], try std.fmt.parseInt(u64, args[4], 10), try std.fmt.parseInt(u64, args[5], 10), null, std.Io.File.stdout()) != null) return error.ActivityUnavailable;
    } else if ((args.len == 9 or args.len == 10) and std.mem.eql(u8, args[1], "verified-window")) {
        var digest: [32]u8 = undefined;
        if (args[7].len != digest.len * 2) return error.InvalidArguments;
        const parsed = try std.fmt.hexToBytes(&digest, args[7]);
        if (parsed.len != digest.len) return error.InvalidArguments;
        var token: client.Cancellation = .{};
        const Stop = struct {
            fn run(io: std.Io, cancellation: *client.Cancellation, milliseconds: u64) void {
                std.Io.sleep(io, .fromMilliseconds(@intCast(milliseconds)), .awake) catch return;
                cancellation.requestStop();
            }
        };
        const stopper = if (args.len == 10) try std.Thread.spawn(.{}, Stop.run, .{ init.io, &token, try std.fmt.parseInt(u64, args[9], 10) }) else null;
        defer if (stopper) |thread| thread.join();
        const scoped: client.Requests = .{ .io = init.io, .cancellation = if (stopper != null) &token else null };
        const window = try scoped.readVerifiedActivityWindow(args[2], args[3], try std.fmt.parseInt(u64, args[4], 10), try std.fmt.parseInt(u64, args[5], 10), .{ .bytes = try std.fmt.parseInt(u64, args[6], 10), .digest = digest }, try std.fmt.parseInt(u64, args[8], 10));
        try std.Io.File.stdout().writeStreamingAll(init.io, window.slice());
    } else if (args.len >= 9 and std.mem.eql(u8, args[1], "verified-scratch")) {
        var digest: [32]u8 = undefined;
        if (args[7].len != digest.len * 2) return error.InvalidArguments;
        if ((try std.fmt.hexToBytes(&digest, args[7])).len != digest.len) return error.InvalidArguments;
        const before = switch (client.hostStatus(init.io, args[2])) {
            .ready => |ready| ready.instance,
            else => return error.HostUnavailable,
        };
        var cancellation: client.Cancellation = .{};
        const StopScratch = struct {
            fn run(io: std.Io, token: *client.Cancellation) void {
                std.Io.sleep(io, .fromMilliseconds(700), .awake) catch return;
                token.requestStop();
            }
        };
        const cancel = std.mem.eql(u8, args[8], "cancel");
        const stopper = if (cancel) try std.Thread.spawn(.{}, StopScratch.run, .{ init.io, &cancellation }) else null;
        defer if (stopper) |thread| thread.join();
        const scoped: client.Requests = .{ .io = init.io, .host_instance = &before, .cancellation = if (cancel) &cancellation else null };
        const path = init.environ_map.get("TMPDIR") orelse return error.InvalidTemporaryDirectory;
        var dir = try std.Io.Dir.cwd().openDir(init.io, path, .{});
        defer dir.close(init.io);
        const content = scoped.readVerifiedActivityScratch(std.heap.c_allocator, dir, args[2], args[3], try std.fmt.parseInt(u64, args[4], 10), try std.fmt.parseInt(u64, args[5], 10), .{ .bytes = try std.fmt.parseInt(u64, args[6], 10), .digest = digest }) catch |err| {
            if (cancel) {
                try std.Io.File.stderr().writeStreamingAll(init.io, "SCRATCH_READ_RETURNED\n");
                try std.Io.sleep(init.io, .fromSeconds(3), .awake);
            }
            return err;
        };
        defer content.close();
        const after = switch (client.hostStatus(init.io, args[2])) {
            .ready => |ready| ready.instance,
            else => return error.HostUnavailable,
        };
        if (!std.mem.eql(u8, &before, &after)) return error.HostInstanceChanged;
        var buffer: [4096]u8 = undefined;
        for (args[8..]) |offset| {
            const count = try content.readAt(try std.fmt.parseInt(u64, offset, 10), &buffer);
            try std.Io.File.stdout().writeStreamingAll(init.io, buffer[0..count]);
        }
    } else if (args.len == 5 and std.mem.eql(u8, args[1], "prefix")) {
        var buffer: [4096]u8 = undefined;
        switch (try requests.readActivityPrefix(args[2], args[3], try std.fmt.parseInt(u64, args[4], 10), &buffer)) {
            .line => |line| try std.Io.File.stdout().writeStreamingAll(init.io, line),
            .failure => return error.ActivityUnavailable,
        }
    } else return error.InvalidArguments;
}
