const std = @import("std");
const client = @import("rui_client");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.c_allocator);
    defer std.heap.c_allocator.free(args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "layout")) {
        var buffer: [128]u8 = undefined;
        try std.Io.File.stdout().writeStreamingAll(init.io, try std.fmt.bufPrint(&buffer, "activity page={d} cursor={d} bytes (fixed owned values)\n", .{ @sizeOf(client.ActivityPage), @sizeOf(client.ActivityCursor) }));
        return;
    }
    const requests: client.Requests = .{ .io = init.io };
    if (args.len == 8 and std.mem.eql(u8, args[1], "page")) {
        const reply = try requests.activityPage(args[2], args[3], .{
            .end = if (std.mem.eql(u8, args[4], "null")) null else try std.fmt.parseInt(u64, args[4], 10),
            .position = try std.fmt.parseInt(u64, args[5], 10),
            .ordinal = if (std.mem.eql(u8, args[6], "null")) null else try std.fmt.parseInt(u64, args[6], 10),
            .direction = std.meta.stringToEnum(@FieldType(client.ActivityCursor, "direction"), args[7]) orelse return error.InvalidArguments,
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
        const position = try std.fmt.parseInt(u64, args[4], 10);
        const ordinal = try std.fmt.parseInt(u64, args[5], 10);
        var cursor: client.ActivityCursor = .{};
        while (true) {
            const page = switch (try requests.activityPage(args[2], args[3], cursor)) {
                .page => |page| page,
                .failure => return error.ActivityUnavailable,
            };
            for (page.facts.items[0..page.facts.count]) |item| if (item.position == position and item.ordinal == ordinal) {
                const reference = switch (item.value) {
                    .admission, .user => |message| message.content,
                    .assistant, .tool_result => |content| content,
                    .outcome => |outcome| outcome.content orelse return error.ActivityUnavailable,
                    else => return error.ActivityUnavailable,
                };
                if (try requests.readActivityContent(args[2], args[3], position, ordinal, .{ .bytes = reference.length, .digest = reference.digest }, std.Io.File.stdout()) != null) return error.ActivityUnavailable;
                return;
            };
            cursor = page.continuation() orelse return error.ActivityUnavailable;
        }
    } else if (args.len == 6 and std.mem.eql(u8, args[1], "field")) {
        const field = std.meta.stringToEnum(client.ProposalField, args[5]) orelse return error.InvalidArguments;
        const position = try std.fmt.parseInt(u64, args[4], 10);
        var cursor: client.ActivityCursor = .{};
        while (true) {
            const page = switch (try requests.activityPage(args[2], args[3], cursor)) {
                .page => |page| page,
                .failure => return error.ActivityUnavailable,
            };
            for (page.facts.items[0..page.facts.count]) |item| if (item.position == position and item.value == .call) {
                const reference = item.value.call.fields[@intFromEnum(field)];
                if (try requests.readProposalField(args[2], args[3], position, field, .{ .bytes = reference.length, .digest = reference.digest }, std.Io.File.stdout()) != null) return error.ActivityUnavailable;
                return;
            };
            cursor = page.continuation() orelse return error.ActivityUnavailable;
        }
    } else return error.InvalidArguments;
}
