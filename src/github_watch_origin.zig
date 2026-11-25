const std = @import("std");

/// Test fixtures may receive credentials only at this literal loopback origin.
pub fn validateLoopback(origin: []const u8) error{InvalidTestOrigin}!void {
    const prefix = "http://127.0.0.1:";
    if (!std.mem.startsWith(u8, origin, prefix)) return error.InvalidTestOrigin;
    const port_text = origin[prefix.len..];
    if (port_text.len == 0 or port_text.len > 5) return error.InvalidTestOrigin;
    for (port_text) |c| if (!std.ascii.isDigit(c)) return error.InvalidTestOrigin;
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidTestOrigin;
    if (port == 0) return error.InvalidTestOrigin;
}

test "PRW-33 fixture origin is restricted to numeric IPv4 loopback" {
    try validateLoopback("http://127.0.0.1:1234");
    for ([_][]const u8{ "http://localhost:1234", "https://127.0.0.1:1234", "http://127.0.0.2:1234", "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:4@evil", "http://127.0.0.1:4/path" }) |origin| try std.testing.expectError(error.InvalidTestOrigin, validateLoopback(origin));
}
