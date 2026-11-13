//! The providers a Host can serve and the facts each one fixes, in one
//! table. Core asks a provider for a fact here and never switches on which
//! provider it is. A leaf, so the modules that `protocol` builds on can name
//! a provider too.
const std = @import("std");

/// The subscription backend endpoint.
pub const managed_endpoint = "https://chatgpt.com/backend-api/codex/responses";
/// The API Responses endpoint.
pub const api_endpoint = "https://api.openai.com/v1/responses";

/// A provider a Host can serve.
pub const Provider = enum {
    codex,
    openai,
    chatgpt,

    /// The request and output grammar a new Session of this provider pins.
    pub fn codec(self: Provider) Codec {
        return self.facts().codec;
    }

    /// The provider as the person knows it, where prose names it: a band,
    /// the Host line, /status, a refusal.
    pub fn shown(self: Provider) []const u8 {
        return self.facts().shown;
    }

    /// The short label of what a person signed in with, where a sign-in is
    /// chosen or read beside a model: the picker's control, the Session line
    /// and the first-run choice. Short, so a narrow pane keeps it whole.
    pub fn signIn(self: Provider) []const u8 {
        return self.facts().sign_in;
    }

    /// The shell command that signs this provider in, or null while Rui
    /// has none for it; every renderer and `rui auth login` read this.
    pub fn login(self: Provider) ?[]const u8 {
        return switch (self) {
            inline else => |provider| if (comptime provider.facts().login) "rui auth login " ++ @tagName(provider) else null,
        };
    }

    /// Whether this provider runs the tool `name` itself, as it runs
    /// hosted `web_search`.
    pub fn runsTool(self: Provider, name: []const u8) bool {
        for (self.facts().runs_tools) |tool| if (std.mem.eql(u8, tool, name)) return true;
        return false;
    }

    /// The table: the one switch on which provider it is.
    pub fn facts(self: Provider) Facts {
        return switch (self) {
            .codex => .{ .endpoint = managed_endpoint, .codec = .@"openai-responses/2", .shown = "ChatGPT (device code)", .sign_in = "Codex", .credential = .sign_in, .login = true, .model_list = .catalog, .runs_tools = &.{"web_search"} },
            .openai => .{ .endpoint = api_endpoint, .codec = .@"openai-responses/2", .shown = "OpenAI", .sign_in = "API key", .credential = .api_key, .login = true, .model_list = .live, .runs_tools = &.{"web_search"} },
            .chatgpt => .{ .endpoint = api_endpoint, .codec = .@"openai-responses/3", .shown = "ChatGPT", .sign_in = "ChatGPT", .credential = .sign_in, .login = true, .model_list = .catalog, .runs_tools = &.{"web_search"} },
        };
    }

    /// The one provider whose model list is fetched live: the Host keeps
    /// one live list, so a second one is a compile error.
    pub fn onlyLiveList() Provider {
        return comptime only("model_list", Facts.ModelList.live);
    }

    fn only(comptime field: []const u8, comptime value: anytype) Provider {
        var found: ?Provider = null;
        for (std.enums.values(Provider)) |provider| if (@field(provider.facts(), field) == value) {
            if (found != null) @compileError("more than one provider has " ++ field ++ " " ++ @tagName(value));
            found = provider;
        };
        return found orelse @compileError("no provider has " ++ field ++ " " ++ @tagName(value));
    }
};

/// What a provider fixes for every Host that serves it.
pub const Facts = struct {
    /// The provider-owned destination for its credential.
    endpoint: []const u8,
    codec: Codec,
    shown: []const u8,
    sign_in: []const u8,
    credential: Credential,
    /// Whether `rui auth login` signs this provider in.
    login: bool,
    model_list: ModelList,
    /// The tools the provider runs on its side, by the names a `tools` list
    /// gives them. A Session of another provider cannot name them.
    runs_tools: []const []const u8,

    /// What a person gives Rui to use this provider: a sign-in the Host
    /// renews, or a key that only a new key replaces.
    pub const Credential = enum { sign_in, api_key };
    /// Where the model picker's list comes from: Rui's catalog, or the
    /// provider's own list, fetched once as the Host starts.
    pub const ModelList = enum { catalog, live };
};

/// A provider grammar and its version, as a Session pins it. A version's
/// requests never change shape, so a pinned Session's prompt cache holds.
/// New Sessions pin the provider's current codec; a Session pinned to an
/// older one keeps it.
pub const Codec = enum { @"openai-responses/1", @"openai-responses/2", @"openai-responses/3" };

test "every OpenAI provider runs web_search, and none runs bash" {
    for (std.enums.values(Provider)) |provider| {
        try std.testing.expect(provider.runsTool("web_search"));
        try std.testing.expect(!provider.runsTool("bash"));
    }
}

test "one provider fetches its model list live" {
    try std.testing.expectEqual(Provider.openai, comptime Provider.onlyLiveList());
}

test "every provider's name and sign-in read apart from the others', and only a provider with a login names one" {
    for (std.enums.values(Provider), 0..) |provider, at| {
        for (std.enums.values(Provider)[at + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, provider.signIn(), other.signIn()));
            try std.testing.expect(!std.mem.eql(u8, provider.shown(), other.shown()));
            // The typed /model word is a sign-in's first word.
            try std.testing.expect(!std.ascii.eqlIgnoreCase(firstWord(provider.signIn()), firstWord(other.signIn())));
        }
        if (provider.login()) |command| try std.testing.expect(std.mem.endsWith(u8, command, @tagName(provider)));
    }
    try std.testing.expectEqualStrings("Codex", Provider.codex.signIn());
    try std.testing.expectEqualStrings("ChatGPT (device code)", Provider.codex.shown());
    try std.testing.expectEqualStrings("ChatGPT", Provider.chatgpt.signIn());
    try std.testing.expectEqualStrings("API key", Provider.openai.signIn());
    try std.testing.expectEqualStrings("rui auth login codex", Provider.codex.login().?);
    try std.testing.expectEqualStrings("rui auth login chatgpt", Provider.chatgpt.login().?);
}

fn firstWord(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len];
}

test "every provider owns an HTTPS endpoint" {
    for (std.enums.values(Provider)) |provider| {
        try std.testing.expect(std.mem.startsWith(u8, provider.facts().endpoint, "https://"));
        try std.testing.expect(std.mem.endsWith(u8, provider.facts().endpoint, "/responses"));
    }
}
