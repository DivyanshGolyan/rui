//! The Store's reading of a replay Wire and Binding from its values. A provider and a codec
//! become a `replay_binding.Wire` only here; the sites that decide replay call these
//! helpers instead of spelling the connection name or the dialect themselves.
//!
//! Until the codec moves from `session` to `session_revision`, a Session's bags share its
//! one Wire, so `producerOf` gives a stored item the request's Wire. Replacing that
//! interim is the one change this file takes when the Store carries each producer's Wire.

const provider_name = @import("../../provider_name.zig");
const codecs = @import("../../codecs.zig");
const replay_binding = @import("../../replay_binding.zig");

/// The Wire of a provider and codec. The connection name is the provider's stored text,
/// which is a static string, so the Wire needs no owner.
pub fn wireOf(provider: provider_name.Provider, codec: provider_name.Codec) replay_binding.Wire {
    return .{ .connection = @tagName(provider), .dialect = codecs.dialect(codec) };
}

/// The request's Binding: its Wire and the model it asks for.
pub fn bindingOf(wire: replay_binding.Wire, model: []const u8) replay_binding.Binding {
    return .{ .wire = wire, .model = model };
}

/// A stored item's Binding, given the model that produced it. Interim: the producer's Wire
/// is the request's (see the file comment).
pub fn producerOf(request: replay_binding.Binding, model: []const u8) replay_binding.Binding {
    return .{ .wire = request.wire, .model = model };
}
