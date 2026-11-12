//! Launch-frame configuration kept at one Host-owned address until shutdown.
const std = @import("std");
const frame = @import("../launch_frame.zig");
const http = @import("../http1/request.zig");

pub const default_timeout_ms = frame.default_mcp_call_timeout_ms;
pub const Server = struct {
    name: []u8,
    url: []u8,
    token: []u8,
    target: http.Target,
    timeout_ms: u64,
};

pub const Servers = struct {
    entries: []Server = &.{},

    pub fn init(self: *Servers, allocator: std.mem.Allocator, input: []const frame.Frame.McpServer) !void {
        self.entries = try allocator.alloc(Server, input.len);
        var initialized: usize = 0;
        errdefer {
            for (self.entries[0..initialized]) |entry| freeServer(allocator, entry);
            allocator.free(self.entries);
            self.entries = &.{};
        }
        for (input, self.entries) |*source, *entry| {
            const name = try allocator.dupe(u8, source.name.slice());
            errdefer allocator.free(name);
            const url = try allocator.dupe(u8, source.url.slice());
            errdefer allocator.free(url);
            const token = try allocator.dupe(u8, source.bearer_token.slice());
            errdefer {
                wipeToken(allocator, token);
            }
            entry.* = .{ .name = name, .url = url, .token = token, .target = try http.parseTarget(url), .timeout_ms = if (source.call_timeout_ms == 0) default_timeout_ms else source.call_timeout_ms };
            initialized += 1;
        }
    }

    pub fn deinit(self: *Servers, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| freeServer(allocator, entry);
        allocator.free(self.entries);
        self.entries = &.{};
    }

    fn wipeToken(allocator: std.mem.Allocator, token: []u8) void {
        std.crypto.secureZero(u8, token);
        // Keep the wipe intact; Allocator.free would write debug poison over
        // these bytes before handing them back to the underlying allocator.
        if (token.len != 0) allocator.rawFree(token, .of(u8), @returnAddress());
    }

    fn freeServer(allocator: std.mem.Allocator, entry: Server) void {
        wipeToken(allocator, entry.token);
        allocator.free(entry.url);
        allocator.free(entry.name);
    }
};

test "MCP Host configurations own target strings and wipe tokens" {
    const gpa = std.testing.allocator;
    const source = try gpa.create(frame.Frame.McpServer);
    defer gpa.destroy(source);
    source.* = .{};
    defer source.bearer_token.wipe();
    try source.name.set("docs");
    try source.url.set("http://127.0.0.1:4567/mcp?q=1");
    @memcpy(source.bearer_token.bytes[0..6], "secret");
    source.bearer_token.len = 6;
    const memory = try gpa.alloc(u8, 4096);
    defer gpa.free(memory);
    var fixed: std.heap.FixedBufferAllocator = .init(memory);
    var configs: Servers = .{};
    try configs.init(fixed.allocator(), @as(*[1]frame.Frame.McpServer, @ptrCast(source)));
    source.bearer_token.wipe();
    try source.url.set("http://127.0.0.1:1/changed");
    const token = configs.entries[0].token;
    try std.testing.expectEqualStrings("secret", token);
    try std.testing.expectEqualStrings("127.0.0.1:4567", configs.entries[0].target.authority);
    try std.testing.expectEqualStrings("/mcp?q=1", configs.entries[0].target.path);
    try std.testing.expectEqual(@as(u64, 600_000), configs.entries[0].timeout_ms);
    configs.deinit(fixed.allocator());
    // FixedBufferAllocator releases no backing memory, so this observes the
    // owned bytes after disposal without reading a freed allocation.
    try std.testing.expect(std.mem.allEqual(u8, token, 0));
}
