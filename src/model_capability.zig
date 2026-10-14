const protocol = @import("protocol.zig");
const provider_selection = @import("provider_selection.zig");

// The Codex adapter's local capability, independent of transport or credentials.
pub const provider_label = "codex";
pub const recommended_model = "gpt-6-luna";

/// Local identifier syntax, not a catalog, qualification or account entitlement.
pub fn validModel(model: []const u8) bool {
    if (model.len == 0 or model.len > protocol.max_model_bytes) return false;
    for (model) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

pub fn capability(readiness: provider_selection.Readiness) provider_selection.Capability {
    return .{ .name = provider_label, .recommended_model = recommended_model, .valid_model = validModel, .readiness = readiness };
}
