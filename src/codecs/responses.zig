//! The OpenAI Responses codec (`openai-responses/1`), serving the `codex`
//! provider.
const codec_abi = @import("../codec_abi.zig");

pub const manifest: codec_abi.Manifest = .{
    .observe = .{
        .request_id = "x-request-id",
        .model = "openai-model",
        .alternate_model = "x-openai-model",
        .turn_state = "x-codex-turn-state",
    },
};
