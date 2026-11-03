//! The providers a Host can serve and the facts each one fixes, in one
//! table. Core asks a provider for a fact here and never switches on which
//! provider it is. A leaf, so the modules that `protocol` builds on can name
//! a provider too.
const std = @import("std");

/// A provider a Host can serve.
pub const Provider = enum {
    codex,
    openai,

    /// The request and output grammar a new Session of this provider pins.
    pub fn codec(self: Provider) Codec {
        return self.facts().codec;
    }

    /// The provider as the person knows it, in screen text.
    pub fn shown(self: Provider) []const u8 {
        return self.facts().shown;
    }

    /// What a person signed in with, as the terminal names this provider.
    pub fn signIn(self: Provider) []const u8 {
        return self.facts().sign_in;
    }

    /// The shell command that signs this provider in.
    pub fn login(self: Provider) []const u8 {
        return switch (self) {
            inline else => |provider| "rui auth login " ++ @tagName(provider),
        };
    }

    /// The table: the one switch on which provider it is.
    pub fn facts(self: Provider) Facts {
        return switch (self) {
            .codex => .{ .codec = .@"openai-responses/1", .shown = "ChatGPT", .sign_in = "ChatGPT", .credential = .sign_in, .model_list = .table },
            .openai => .{ .codec = .@"openai-responses/1", .shown = "OpenAI", .sign_in = "API key", .credential = .api_key, .model_list = .live },
        };
    }

    /// The one provider whose credential is `kind`. A second one is a
    /// compile error: a view that names it must then learn which provider
    /// a failure belongs to.
    pub fn onlyWith(comptime kind: Facts.Credential) Provider {
        comptime {
            var found: ?Provider = null;
            for (std.enums.values(Provider)) |provider| if (provider.facts().credential == kind) {
                if (found != null) @compileError("more than one provider has a " ++ @tagName(kind) ++ " credential");
                found = provider;
            };
            return found orelse @compileError("no provider has a " ++ @tagName(kind) ++ " credential");
        }
    }
};

/// What a provider fixes for every Host that serves it.
pub const Facts = struct {
    codec: Codec,
    shown: []const u8,
    sign_in: []const u8,
    credential: Credential,
    model_list: ModelList,

    /// What a person gives Rui to use this provider: a sign-in the Host
    /// renews, or a key that only a new key replaces.
    pub const Credential = enum { sign_in, api_key };
    /// Where the model picker's list comes from: Rui's table, or the
    /// provider's own list, fetched once as the Host starts.
    pub const ModelList = enum { table, live };
};

/// A provider grammar and its version, as a Session pins it. A version's
/// requests never change shape, so a pinned Session's prompt cache holds.
pub const Codec = enum { @"openai-responses/1" };

test "each credential kind names its one provider" {
    try std.testing.expectEqual(Provider.codex, comptime Provider.onlyWith(.sign_in));
    try std.testing.expectEqual(Provider.openai, comptime Provider.onlyWith(.api_key));
}
