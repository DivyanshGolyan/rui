const std = @import("std");
const History = @import("SessionHistory");
const client = History.client;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    defer std.heap.c_allocator.free(args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "layout")) {
        var buffer: [256]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&buffer, "Prepared={d} page={d} cursor={d} scratch_bound={d} item_bound={d}\n", .{ @sizeOf(History.Prepared), @sizeOf(client.ConversationPage), @sizeOf(client.ConversationCursor), History.max_scratch_bytes, History.item_bytes }));
        return;
    }
    if (args.len != 8) return error.InvalidArguments;
    const cursor: client.ConversationCursor = .{ .end = try std.fmt.parseInt(u64, args[4], 10), .before_position = try std.fmt.parseInt(u64, args[5], 10), .before_ordinal = try std.fmt.parseInt(u64, args[6], 10) };
    const scratch = try std.Io.Dir.cwd().createFile(init.io, args[7], .{ .read = true });
    defer scratch.close(init.io);
    const requests: client.Requests = .{ .io = init.io };
    const prepared = History.prepare(requests, args[2], args[3], cursor, scratch) catch |err| {
        // This driver checks preparation only. The real Frontend/PTY owns the
        // fault/retry cursor oracle; reconstructing argv cannot prove it.
        var buffer: [160]u8 = undefined;
        try std.Io.File.stderr().writeStreamingAll(init.io, try std.fmt.bufPrint(&buffer, "prepare failed at {d}/{d}/{d}: {s}\n", .{ cursor.end, cursor.before_position, cursor.before_ordinal, @errorName(err) }));
        return err;
    };
    const Sink = struct {
        io: std.Io,
        pub fn feed(self: @This(), bytes: []const u8) !void {
            try std.Io.File.stdout().writeStreamingAll(self.io, bytes);
        }
    };
    try prepared.render(init.io, scratch, Sink{ .io = init.io });
    var buffer: [160]u8 = undefined;
    if (prepared.continuation()) |next| {
        try std.Io.File.stderr().writeStreamingAll(init.io, try std.fmt.bufPrint(&buffer, "next {d}/{d}/{d}\n", .{ next.end, next.before_position, next.before_ordinal }));
    } else try std.Io.File.stderr().writeStreamingAll(init.io, "next none\n");
}
