//! The request header names the Host itself sets on a provider request, as
//! plain names. A connection may not set any of them. This file is a pure leaf
//! (std only): the settings parser, the provider transport and the shells all
//! read this one list. Its agreement with the owners of these names is checked
//! where both are visible: `h2.owned_fields` and each codec's turn-state header
//! in src/provider.zig tests.
const std = @import("std");

pub const content_type = "content-type";

/// The names the Host sets on every provider request. The routing name is the
/// Responses codec's turn-state header (`codecs/responses.zig`).
pub const request_fields = [_][]const u8{ content_type, "authorization", "chatgpt-account-id", "user-agent", "x-openai-fedramp", "x-codex-turn-state" };

/// The framing names the HTTP/2 engine owns (`h2.owned_fields`).
pub const transport_fields = [_][]const u8{ "content-length", "accept-encoding", "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "host" };

pub fn hostField(name: []const u8) bool {
    for (request_fields ++ transport_fields) |owned| {
        if (std.mem.eql(u8, name, owned)) return true;
    }
    return false;
}

test "host-owned names are compared as whole names" {
    try std.testing.expect(hostField("authorization"));
    try std.testing.expect(hostField("host"));
    try std.testing.expect(!hostField("authorizations"));
    try std.testing.expect(!hostField("Authorization"));
}
