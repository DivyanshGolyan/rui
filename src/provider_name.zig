const std = @import("std");

pub const managed_endpoint = "https://chatgpt.com/backend-api/codex/responses";
pub const api_endpoint = "https://api.openai.com/v1/responses";

pub const Provider = enum {
    codex,
    openai,
    chatgpt,

    pub fn codec(self: Provider) Codec {
        return self.facts().codec;
    }

    pub fn shown(self: Provider) []const u8 {
        return self.facts().shown;
    }

    pub fn signIn(self: Provider) []const u8 {
        return self.facts().sign_in;
    }

    pub fn login(self: Provider) ?[]const u8 {
        return self.facts().login;
    }

    pub fn usage(self: Provider) ?[]const u8 {
        return self.facts().usage;
    }

    pub fn sameAccount(self: Provider) ?Provider {
        return self.facts().same_account;
    }

    pub fn runsTool(self: Provider, name: []const u8) bool {
        for (self.facts().runs_tools) |tool| if (std.mem.eql(u8, tool, name)) return true;
        return false;
    }

    pub fn facts(self: Provider) Facts {
        return switch (self) {
            .codex => .{ .endpoint = managed_endpoint, .codec = .@"openai-responses/2", .shown = "ChatGPT (device code)", .sign_in = "ChatGPT", .credential = .sign_in, .login = "rui auth login chatgpt --device-code", .model_list = .catalog, .usage = null, .runs_tools = &.{"web_search"}, .same_account = .chatgpt },
            .openai => .{ .endpoint = api_endpoint, .codec = .@"openai-responses/2", .shown = "OpenAI", .sign_in = "API key", .credential = .api_key, .login = "rui auth login openai", .model_list = .live, .usage = null, .runs_tools = &.{"web_search"}, .same_account = null },
            .chatgpt => .{ .endpoint = api_endpoint, .codec = .@"openai-responses/3", .shown = "ChatGPT", .sign_in = "ChatGPT", .credential = .sign_in, .login = "rui auth login chatgpt", .model_list = .live, .usage = "Manage usage: https://chatgpt.com/settings/usage", .runs_tools = &.{"web_search"}, .same_account = .codex },
        };
    }
};

pub const Facts = struct {
    endpoint: []const u8,
    codec: Codec,
    shown: []const u8,
    sign_in: []const u8,
    credential: Credential,
    login: ?[]const u8,
    model_list: ModelList,
    usage: ?[]const u8,
    runs_tools: []const []const u8,
    same_account: ?Provider,

    pub const Credential = enum { sign_in, api_key };
    pub const ModelList = enum { catalog, live };
};

pub const Codec = enum { @"openai-responses/1", @"openai-responses/2", @"openai-responses/3", @"anthropic-messages/1" };

test "every OpenAI provider runs web_search, and none runs bash" {
    for (std.enums.values(Provider)) |provider| {
        try std.testing.expect(provider.runsTool("web_search"));
        try std.testing.expect(!provider.runsTool("bash"));
    }
}

test "every provider's name reads apart, its sign-in reads the same exactly within its account, and its login is a terminal command" {
    for (std.enums.values(Provider), 0..) |provider, at| {
        for (std.enums.values(Provider)[at + 1 ..]) |other| {
            const one_account = provider.sameAccount() == other;
            try std.testing.expectEqual(one_account, std.mem.eql(u8, provider.signIn(), other.signIn()));
            try std.testing.expect(!std.mem.eql(u8, provider.shown(), other.shown()));
            if (provider.login()) |command| try std.testing.expect(!std.mem.eql(u8, command, other.login() orelse ""));
        }
        if (provider.login()) |command| try std.testing.expect(std.mem.startsWith(u8, command, "rui auth login "));
        try std.testing.expect(std.ascii.findIgnoreCase(provider.signIn(), "codex") == null);
        try std.testing.expect(std.ascii.findIgnoreCase(provider.shown(), "codex") == null);
    }
    try std.testing.expectEqualStrings("ChatGPT", Provider.codex.signIn());
    try std.testing.expectEqualStrings("ChatGPT (device code)", Provider.codex.shown());
    try std.testing.expectEqualStrings("ChatGPT", Provider.chatgpt.signIn());
    try std.testing.expectEqualStrings("API key", Provider.openai.signIn());
    try std.testing.expectEqualStrings("rui auth login chatgpt --device-code", Provider.codex.login().?);
    try std.testing.expectEqualStrings("rui auth login chatgpt", Provider.chatgpt.login().?);
    try std.testing.expectEqualStrings("rui auth login openai", Provider.openai.login().?);
}

test "two providers share an account only as each other's, and only as sign-ins" {
    for (std.enums.values(Provider)) |provider| {
        const other = provider.sameAccount() orelse continue;
        try std.testing.expect(other != provider);
        try std.testing.expectEqual(@as(?Provider, provider), other.sameAccount());
        try std.testing.expectEqual(Facts.Credential.sign_in, provider.facts().credential);
        try std.testing.expectEqual(Facts.Credential.sign_in, other.facts().credential);
    }
    try std.testing.expectEqual(@as(?Provider, .chatgpt), Provider.codex.sameAccount());
    try std.testing.expectEqual(@as(?Provider, .codex), Provider.chatgpt.sameAccount());
    try std.testing.expectEqual(@as(?Provider, null), Provider.openai.sameAccount());
}

test "every provider owns an HTTPS endpoint" {
    for (std.enums.values(Provider)) |provider| {
        try std.testing.expect(std.mem.startsWith(u8, provider.facts().endpoint, "https://"));
        try std.testing.expect(std.mem.endsWith(u8, provider.facts().endpoint, "/responses"));
    }
}
pub const sign_in_issuer = @import("codex_token_wire.zig").issuer;
