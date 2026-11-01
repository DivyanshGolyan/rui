//! The codecs this Host serves, by the codec name a Session pins.
const codec_abi = @import("codec_abi.zig");
const protocol = @import("protocol.zig");
const responses = @import("codecs/responses.zig");

pub fn manifest(codec: protocol.Codec) *const codec_abi.Manifest {
    return switch (codec) {
        .@"openai-responses/1" => &responses.manifest,
    };
}

comptime {
    for (@typeInfo(protocol.Codec).@"enum".field_names) |name| {
        if (!manifest(@field(protocol.Codec, name)).valid()) @compileError("codec " ++ name ++ " observes a header that is not a lowercase token");
    }
}
