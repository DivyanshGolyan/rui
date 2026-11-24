//! Connection tests that need the owners a functional core cannot import:
//! the host's header owner (`provider.hostField`) and the bundled presets'
//! owners. The core's own tests are in src/connection.zig.

const std = @import("std");
const connection = @import("../connection.zig");
const provider = @import("../provider.zig");

fn testOk(arena: std.mem.Allocator, text: []const u8) !connection.Connection {
    return switch (try connection.parse(arena, text, provider.hostField)) {
        .ok => |value| value,
        .refused => error.UnexpectedRefusal,
    };
}

const base_document =
    \\{
    \\  "name": "gateway",
    \\  "label": "Gateway",
    \\  "base_url": "https://gateway.example/v1",
    \\  "credential": {"kind": "key", "source": {"kind": "saved"}, "placement": "x-api-key"},
    \\  "headers": [],
    \\  "refusals": [],
    \\  "formats": [{"family": "responses", "dialect": "openai-responses/3", "web_search": false}],
    \\  "assign": [],
    \\  "models": {"list": "openai"}
    \\}
;

test "a connection may not set a header the host owns, or the key's own placement header" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var value = try testOk(allocator, base_document);

    // The key's placement header is x-api-key here, so a literal of that name is refused.
    // content-type and te are host-owned (provider.hostField) and refused too.
    for ([_][]const u8{ "x-api-key", "content-type", "te", "authorization", "host" }) |name| {
        value.headers = &.{.{ .name = name, .from = .{ .literal = "a" } }};
        const found = connection.validate(&value, provider.hostField) orelse return error.TestExpectedRefusal;
        try std.testing.expectEqual(connection.Refusal.Reason.reserved_header, found.reason);
    }
    value.headers = &.{.{ .name = "x-team", .from = .{ .literal = "a" } }};
    try std.testing.expect(connection.validate(&value, provider.hostField) == null);
}
