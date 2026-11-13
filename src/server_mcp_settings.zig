//! The MCP connection values consumed by the Host's discovery/runtime owners.
//! The Host projects Settings into this shared discovery/runtime value.
const std = @import("std");
const hs = @import("host_settings.zig");
const protocol = @import("protocol.zig");
const api_key = @import("api_key.zig");
const http = @import("http1/request.zig");

pub const Server = struct {
    name: protocol.Bounded(hs.max_mcp_name_bytes) = .{},
    url: protocol.Bounded(http.max_url_bytes) = .{},
    bearer_token: api_key.Key = .{},
    call_timeout_ms: u32 = 0,
};

/// Owns one bounded projection, including token copies, until deinit.
pub const Connections = struct {
    allocator: std.mem.Allocator,
    servers: []Server,

    pub fn init(gpa: std.mem.Allocator, settings: *const hs.Settings) !Connections {
        const servers = try gpa.alloc(Server, settings.tools.mcp.len);
        for (servers, settings.tools.mcp.names[0..settings.tools.mcp.len], settings.tools.mcp.slice()) |*dest, *name, *source| {
            dest.* = .{};
            dest.name.set(name.slice()) catch unreachable;
            dest.url.set(source.url.slice()) catch unreachable;
            dest.bearer_token = source.bearer_token.bytes;
            dest.call_timeout_ms = source.call_timeout_ms.value;
        }
        return .{ .allocator = gpa, .servers = servers };
    }

    pub fn deinit(self: *Connections) void {
        for (self.servers) |*server| server.bearer_token.wipe();
        self.allocator.free(self.servers);
    }
};

test "Host MCP projection borrows settings facts and owns wiped token copies" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(hs.Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    settings.tools.mcp.len = 1;
    try settings.tools.mcp.names[0].set("docs");
    try settings.tools.mcp.values[0].url.text.set("http://127.0.0.1:9/mcp");
    settings.tools.mcp.values[0].bearer_token.bytes.len = 3;
    @memcpy(settings.tools.mcp.values[0].bearer_token.bytes.bytes[0..3], "key");
    settings.tools.mcp.values[0].call_timeout_ms.value = 17;
    var connections = try Connections.init(gpa, settings);
    defer connections.deinit();
    try std.testing.expectEqualStrings("docs", connections.servers[0].name.slice());
    try std.testing.expectEqualStrings("http://127.0.0.1:9/mcp", connections.servers[0].url.slice());
    try std.testing.expectEqualStrings("key", connections.servers[0].bearer_token.slice());
    try std.testing.expectEqual(@as(u32, 17), connections.servers[0].call_timeout_ms);
    settings.wipe();
    try std.testing.expectEqualStrings("key", connections.servers[0].bearer_token.slice());
}
