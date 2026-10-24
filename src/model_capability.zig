const product_defaults = @import("product_defaults.zig");
const protocol = @import("protocol.zig");
const provider_selection = @import("provider_selection.zig");

// The Codex adapter's local capability, independent of transport or credentials.
pub const provider_label = "codex";

pub const CompactionPolicy = struct {
    compaction_trigger: ?u64,
    output_reservation: u64,
};

/// Codex 970111f6cb62cc02fe36a82ea7d71b37a2889c97 models-manager/models.json
/// advertises parallel support for all eight IDs, but client.rs
/// disables it for Responses-lite models. Only gpt-5.5 is not lite. This is
/// the effective request policy, not a claim that Rui uses the lite route.
pub fn parallelToolCalls(model: []const u8) bool {
    const std = @import("std");
    return std.mem.eql(u8, model, "gpt-5.5");
}

/// The pinned catalog gives all release-supported IDs a 272000-token window.
/// No alias inference, account entitlement or live qualification is implied.
/// Reservation is extra heuristic headroom, never a provider output limit.
pub fn compactionPolicy(model: []const u8, trigger_override: ?u64, reservation_override: ?u64) CompactionPolicy {
    const automatic: ?u64 = if (product_defaults.supportsModel(model))
        272000 * product_defaults.compaction_trigger_percent / 100
    else
        null;
    return .{
        .compaction_trigger = trigger_override orelse automatic,
        .output_reservation = reservation_override orelse product_defaults.output_reservation,
    };
}

/// Local identifier syntax, not a catalog, qualification or account entitlement.
pub fn validModel(model: []const u8) bool {
    if (model.len == 0 or model.len > protocol.max_model_bytes) return false;
    for (model) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

pub fn capability(readiness: provider_selection.Readiness) provider_selection.Capability {
    return .{ .name = provider_label, .recommended_model = product_defaults.recommended_model, .valid_model = validModel, .readiness = readiness };
}

test "supported model compaction defaults and exact identifier boundary" {
    const std = @import("std");
    for (product_defaults.supported_models) |model| {
        const policy = compactionPolicy(model, null, null);
        try std.testing.expectEqual(@as(?u64, 244800), policy.compaction_trigger);
        try std.testing.expectEqual(@as(u64, 0), policy.output_reservation);
        const overridden = compactionPolicy(model, 7, 3);
        try std.testing.expectEqual(@as(?u64, 7), overridden.compaction_trigger);
        try std.testing.expectEqual(@as(u64, 3), overridden.output_reservation);
    }
    for ([_][]const u8{ "model-a", "gpt-6-luna-alias", "GPT-6-LUNA", "gpt-6-lun" }) |other|
        try std.testing.expectEqual(@as(?u64, null), compactionPolicy(other, null, null).compaction_trigger);
    try std.testing.expectEqual(@as(?u64, 11), compactionPolicy("model-a", 11, null).compaction_trigger);
}
