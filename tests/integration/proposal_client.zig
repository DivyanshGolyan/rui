const std = @import("std");
const client = @import("rui_client");

// Real typed library consumer. No CLI/opening/draft authority is implied.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    defer std.heap.c_allocator.free(args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "layout")) {
        var buffer: [128]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&buffer, "proposal page={d} cursor={d} bytes (fixed owned values)\n", .{ @sizeOf(client.ProposalPage), @sizeOf(client.ProposalCursor) }));
        return;
    }
    if (args.len != 6) return error.InvalidArguments;
    const requests: client.Requests = .{ .io = init.io };
    if (std.mem.eql(u8, args[1], "page")) {
        const reply = try requests.proposalPage(args[2], args[3], .{
            .end = if (std.mem.eql(u8, args[4], "null")) null else try std.fmt.parseInt(u64, args[4], 10),
            .after = try std.fmt.parseInt(u64, args[5], 10),
        });
        const page = switch (reply) {
            .page => |page| page,
            .failure => return error.ProposalUnavailable,
        };
        var buffer: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(init.io, &buffer);
        try std.json.Stringify.value(.{ .end = page.end, .more = page.more, .next = page.continuation(), .items = page.items[0..page.count] }, .{}, &out.interface);
        try out.interface.flush();
    } else if (std.mem.eql(u8, args[1], "field")) {
        const field = std.meta.stringToEnum(client.ProposalField, args[5]) orelse return error.InvalidArguments;
        if (try requests.readProposalField(args[2], args[3], try std.fmt.parseInt(u64, args[4], 10), field, std.Io.File.stdout()) != null) return error.ProposalUnavailable;
    } else return error.InvalidArguments;
}
