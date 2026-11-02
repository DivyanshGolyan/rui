//! The providers a Host can serve and the grammar each one pins. A leaf, so
//! the modules that `protocol` builds on can name a provider too.

/// A provider a Host can serve.
pub const Provider = enum {
    codex,
    openai,

    /// The request and output grammar a new Session of this provider pins.
    pub fn codec(self: Provider) Codec {
        return switch (self) {
            .codex, .openai => .@"openai-responses/1",
        };
    }

    /// What a person signed in with, as the terminal names this provider.
    pub fn signIn(self: Provider) []const u8 {
        return switch (self) {
            .codex => "ChatGPT",
            .openai => "API key",
        };
    }
};

/// A provider grammar and its version, as a Session pins it. A version's
/// requests never change shape, so a pinned Session's prompt cache holds.
pub const Codec = enum { @"openai-responses/1" };
