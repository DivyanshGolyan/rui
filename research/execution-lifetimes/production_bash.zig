const std = @import("std");
const bash = @import("bash");
const metrics = @import("metrics");
const Track = @import("tracking.zig").Track;
pub fn main(init: std.process.Init) !void {
    var t: Track = .{};
    const cold = try metrics.sample();
    var result = try bash.execute(t.allocator(), init.io, "/tmp", .{ .command = "head -c 65536 /dev/zero", .timeout_ms = 10000 });
    const loaded = try metrics.sample();
    const held = t.live;
    const len = result.stdout.len;
    const status = result.status;
    result.deinit();
    const idle = try metrics.sample();
    std.debug.print("{{\"scope\":\"production Bash, one completed execution\",\"status\":\"{s}\",\"stdout_bytes\":{d},\"allocator_peak\":{d},\"held_live\":{d},\"released_live\":{d},\"cold_physical\":{d},\"held_physical\":{d},\"idle_physical\":{d}}}\n", .{ @tagName(status), len, t.peak, held, t.live, cold.physical_footprint_bytes, loaded.physical_footprint_bytes, idle.physical_footprint_bytes });
    std.debug.assert(t.live == 0);
}
