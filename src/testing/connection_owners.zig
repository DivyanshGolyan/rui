//! Connection tests that need the owners a functional core cannot import: the
//! host's header owner (`provider.hostField`), the provider facts, and the
//! ChatGPT wire facts. The presets are data read by the core's parser; these
//! tests compare them to those owners, so the owner, not a restated literal,
//! decides what a preset says. The core's own tests are in src/connection.zig.

const std = @import("std");
const connection = @import("../connection.zig");
const provider = @import("../provider.zig");
const provider_name = @import("../provider_name.zig");
const chatgpt_plan_wire = @import("../chatgpt_plan_wire.zig");
const codex_token_wire = @import("../codex_token_wire.zig");

fn testOk(arena: std.mem.Allocator, text: []const u8) !connection.Connection {
    return switch (try connection.parse(arena, text, provider.hostField)) {
        .ok => |value| value,
        .refused => error.UnexpectedRefusal,
    };
}

fn oauthOf(c: connection.Connection) connection.OAuth {
    return switch (c.credential) {
        .oauth => |oauth| oauth,
        else => unreachable,
    };
}

fn deviceOf(c: connection.Connection) connection.Device {
    return switch (c.credential) {
        .@"openai-device" => |device| device,
        else => unreachable,
    };
}

fn issuedId(id: connection.OAuth.ClientId) []const u8 {
    return switch (id) {
        .issued_at_sign_in => |text| text,
        else => unreachable,
    };
}

fn literalOf(source: connection.OAuth.LinkSource) []const u8 {
    return switch (source) {
        .literal => |text| text,
        else => unreachable,
    };
}

fn claimOf(source: connection.Header.Source) []const u8 {
    return switch (source) {
        .claim => |name| name,
        else => unreachable,
    };
}

fn keyOf(c: connection.Connection) connection.Key {
    return switch (c.credential) {
        .key => |key| key,
        else => unreachable,
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
    var value = try testOk(arena.allocator(), base_document);

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

const presets = .{
    .{ "chatgpt", @embedFile("../connection_presets/chatgpt.json") },
    .{ "chatgpt-device", @embedFile("../connection_presets/chatgpt-device.json") },
    .{ "openai", @embedFile("../connection_presets/openai.json") },
    .{ "anthropic", @embedFile("../connection_presets/anthropic.json") },
    .{ "custom", @embedFile("../connection_presets/custom.json") },
};

test "every bundled preset parses and validates through the same parser" {
    inline for (presets) |preset| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const value = try testOk(arena.allocator(), preset[1]);
        try std.testing.expectEqualStrings(preset[0], value.name.slice());
        try std.testing.expect(connection.validate(&value, provider.hostField) == null);
    }
}

test "the ChatGPT browser preset holds the owners' sign-in and endpoint facts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var buffer: [256]u8 = undefined;

    const value = try testOk(allocator, presets[0][1]);
    const facts = provider_name.Provider.chatgpt.facts();
    try std.testing.expectEqualStrings(provider_name.Provider.chatgpt.shown(), value.label);
    try std.testing.expectEqualStrings(chatgpt_plan_wire.resource, value.base_url);
    const resolved = try connection.resolve(&value, .{ .id = "gpt-5.1", .native_family = .responses }, &buffer);
    try std.testing.expectEqualStrings(provider_name.api_endpoint, resolved.url);
    try std.testing.expectEqual(facts.codec, resolved.codec);
    try std.testing.expect(value.formats[0].web_search);

    const oauth = oauthOf(value);
    try std.testing.expectEqualStrings(chatgpt_plan_wire.authorize_url, oauth.authorize_url);
    try std.testing.expectEqualStrings(chatgpt_plan_wire.token_url, oauth.token_url);
    try std.testing.expectEqualStrings(chatgpt_plan_wire.scope, oauth.scopes);
    try std.testing.expectEqualStrings(chatgpt_plan_wire.plan_scope, oauth.required_scope);
    try std.testing.expectEqualStrings(chatgpt_plan_wire.resource, oauth.audience);
    try std.testing.expectEqualStrings(chatgpt_plan_wire.first_client_id, issuedId(oauth.client_id));
    try std.testing.expectEqualStrings("agent_name_hint", oauth.link[0].name);
    try std.testing.expectEqualStrings(chatgpt_plan_wire.agent_name, literalOf(oauth.link[0].from));
    try std.testing.expectEqualStrings("ext_agent_host_id", oauth.link[1].name);
    try std.testing.expect(std.meta.activeTag(oauth.link[1].from) == .host_id);
}

test "the ChatGPT device preset holds the owners' client, endpoint and claim headers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var buffer: [256]u8 = undefined;

    const value = try testOk(allocator, presets[1][1]);
    const facts = provider_name.Provider.codex.facts();
    try std.testing.expectEqualStrings(provider_name.Provider.codex.shown(), value.label);
    const resolved = try connection.resolve(&value, .{ .id = "gpt-5.1", .native_family = .responses }, &buffer);
    try std.testing.expectEqualStrings(provider_name.managed_endpoint, resolved.url);
    try std.testing.expectEqual(facts.codec, resolved.codec);
    try std.testing.expectEqualStrings(codex_token_wire.client_id, deviceOf(value).client_id);
    try std.testing.expectEqualStrings(value.base_url, deviceOf(value).audience);
    // The claim names and header names are the preset's own spelling; no owner holds them as constants.
    try std.testing.expectEqualStrings("chatgpt-account-id", value.headers[0].name);
    try std.testing.expectEqualStrings("account_id", claimOf(value.headers[0].from));
    try std.testing.expectEqualStrings("x-openai-fedramp", value.headers[1].name);
    try std.testing.expectEqualStrings("fedramp", claimOf(value.headers[1].from));
}

test "the bundled key presets hold the owners' endpoint and label, and name their placement" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var buffer: [256]u8 = undefined;

    const openai = try testOk(allocator, presets[2][1]);
    try std.testing.expectEqual(connection.Key.Placement.bearer, keyOf(openai).placement);
    try std.testing.expectEqualStrings(provider_name.Provider.openai.shown(), openai.label);
    const openai_resolved = try connection.resolve(&openai, .{ .id = "gpt-5.1", .native_family = .responses }, &buffer);
    try std.testing.expectEqualStrings(provider_name.api_endpoint, openai_resolved.url);
    try std.testing.expectEqual(provider_name.Provider.openai.codec(), openai_resolved.codec);

    // No owner holds the Anthropic endpoint yet; its literal is the only statement of it.
    const anthropic = try testOk(allocator, presets[3][1]);
    try std.testing.expectEqual(connection.Key.Placement.@"x-api-key", keyOf(anthropic).placement);
    const anthropic_resolved = try connection.resolve(&anthropic, .{ .id = "claude-sonnet-4.5", .native_family = .messages }, &buffer);
    try std.testing.expectEqual(connection.Family.messages, anthropic_resolved.family);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", anthropic_resolved.url);
    try std.testing.expectEqual(provider_name.Codec.@"anthropic-messages/1", anthropic_resolved.codec);
}
