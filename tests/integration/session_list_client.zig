const std = @import("std");
const client = @import("rui_client");

// Fixture caller for the public library surface; production CLI presentation
// is a separate slice. The integration runner accepts only complete JSON.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    if (args.len != 5) return error.InvalidArguments;
    const workspace: ?[]const u8 = if (std.mem.eql(u8, args[2], "-")) null else args[2];
    var reply_buffer: client.ReplyBuffer = .{};
    const reply = try client.listSessions(init.io, args[1], workspace, .{
        .after = try std.fmt.parseInt(u64, args[3], 10),
        .ceiling = try std.fmt.parseInt(u64, args[4], 10),
    }, std.Io.File.stdout(), &reply_buffer);
    switch (reply) {
        .report => {},
        .command => return error.ListUnavailable,
    }
}
