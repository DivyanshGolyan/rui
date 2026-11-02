//! The wasm build of scan.zig: one Scan per instance, fed through a window
//! in linear memory.
const scan_zig = @import("scan.zig");

var scan: scan_zig.Scan = .{};
var window: [scan_zig.window_bytes]u8 = undefined;

export fn windowAddress() u32 {
    return @intFromPtr(&window);
}

export fn feed(len: u32) u32 {
    scan.feed(window[0..len]);
    return 0;
}

export fn digestLow() u32 {
    return @truncate(scan.digest);
}
