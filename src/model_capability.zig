const product_defaults = @import("product_defaults.zig");
const protocol = @import("protocol.zig");
const provider_selection = @import("provider_selection.zig");

// The Codex adapter's local capability, independent of transport or credentials.
pub const provider_label = "codex";

pub const CompactionPolicy = struct {
    compaction_trigger: ?u64,
    output_reservation: u64,
};

const KnownModel = struct { name: []const u8, context_tokens: u64 };

/// Exact requested model names with known context windows. This is not a
/// catalog, qualification or entitlement; other valid identifiers still run.
const known_models = [_]KnownModel{
    // Codex metadata 21c16161191ff965031d1ac41fe9046011610743.
    .{ .name = "gpt-6-luna", .context_tokens = 272000 },
};

fn knownModel(model: []const u8) ?KnownModel {
    const std = @import("std");
    for (known_models) |known| if (std.mem.eql(u8, known.name, model)) return known;
    return null;
}

/// Reservation is extra heuristic headroom, never a provider output limit.
pub fn compactionPolicy(model: []const u8, trigger_override: ?u64, reservation_override: ?u64) CompactionPolicy {
    const automatic: ?u64 = if (knownModel(model)) |known|
        known.context_tokens * product_defaults.compaction_trigger_percent / 100
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

test "the recommended model has an automatic compaction threshold; other models do not" {
    const std = @import("std");
    const recommended = compactionPolicy(product_defaults.recommended_model, null, null);
    try std.testing.expectEqual(@as(?u64, 244800), recommended.compaction_trigger);
    try std.testing.expectEqual(@as(u64, 0), recommended.output_reservation);
    for ([_][]const u8{ "model-a", "gpt-6-luna-alias", "GPT-6-LUNA", "gpt-6-lun" }) |other|
        try std.testing.expectEqual(@as(?u64, null), compactionPolicy(other, null, null).compaction_trigger);
    const explicit = compactionPolicy(product_defaults.recommended_model, 7, 3);
    try std.testing.expectEqual(@as(?u64, 7), explicit.compaction_trigger);
    try std.testing.expectEqual(@as(u64, 3), explicit.output_reservation);
    try std.testing.expectEqual(@as(?u64, 11), compactionPolicy("model-a", 11, null).compaction_trigger);
}
