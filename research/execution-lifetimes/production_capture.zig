const std = @import("std");
const provider = @import("provider");
const metrics = @import("metrics");
const Track = @import("tracking.zig").Track;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    const count = try std.fmt.parseInt(usize, args[1], 10);
    std.debug.assert(count == 1 or count == 100);
    var t: Track = .{};
    const cold = try metrics.sample();
    const captures = try t.allocator().alloc(provider.Capture, count);
    for (captures) |*capture| capture.* = provider.Capture.init(t.allocator(), null);
    const content_free = t.live;
    var block: [4096]u8 = @splat('a');
    for (captures) |*capture| {
        try capture.appendSse("data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"");
        try capture.appendSse(&block);
        try capture.appendSse("\"}]}}\n\ndata: {\"type\":\"response.completed\"}\n\n");
        capture.finishSse();
        std.debug.assert(!capture.malformed and !capture.resource_exceeded);
        std.debug.assert(std.mem.eql(u8, capture.text.items.items, &block));
    }
    const loaded = try metrics.sample();
    const held = t.live;
    for (captures) |*capture| capture.deinit();
    t.allocator().free(captures);
    const idle = try metrics.sample();
    std.debug.print("{{\"scope\":\"production Capture parser only; no transport or publication\",\"count\":{d},\"capture_size\":{d},\"text_bytes_each\":4096,\"initial_live\":{d},\"allocator_peak\":{d},\"held_live\":{d},\"released_live\":{d},\"cold_physical\":{d},\"held_physical\":{d},\"idle_physical\":{d}}}\n", .{ count, @sizeOf(provider.Capture), content_free, t.peak, held, t.live, cold.physical_footprint_bytes, loaded.physical_footprint_bytes, idle.physical_footprint_bytes });
    std.debug.assert(t.live == 0);
}
