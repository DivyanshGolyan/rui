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

/// Exact defaults from Codex 970111f6 models-manager/models.json, not backend
/// effective effort or entitlement. Unknown bindings have no inferred default.
pub fn defaultReasoningEffort(model: []const u8) ?protocol.ReasoningEffort {
    const std = @import("std");
    for ([_][]const u8{ "gpt-6-astra", "gpt-6.1-sol", "gpt-5.6-sol" }) |known|
        if (std.mem.eql(u8, model, known)) return .low;
    for ([_][]const u8{ "gpt-6-sol", "gpt-6-luna", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5" }) |known|
        if (std.mem.eql(u8, model, known)) return .medium;
    return null;
}

/// Configuration admission intersects Rui's closed grammar with the pinned
/// model's advertised values. Frozen Operations do not consult this again.
pub fn supportsReasoningEffort(model: []const u8, effort: protocol.ReasoningEffort) bool {
    const std = @import("std");
    if (defaultReasoningEffort(model) == null) return false;
    return switch (effort) {
        .none => false,
        .max => !std.mem.eql(u8, model, "gpt-5.5"),
        .low, .medium, .high, .xhigh => true,
    };
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

test "reasoning effort uses exact catalog defaults and model support without expanding grammar" {
    const std = @import("std");
    for ([_]struct { model: []const u8, default: protocol.ReasoningEffort, max: bool }{
        .{ .model = "gpt-6-luna", .default = .medium, .max = true },
        .{ .model = "gpt-6.1-sol", .default = .low, .max = true },
        .{ .model = "gpt-6-sol", .default = .medium, .max = true },
        .{ .model = "gpt-6-astra", .default = .low, .max = true },
        .{ .model = "gpt-5.6-sol", .default = .low, .max = true },
        .{ .model = "gpt-5.6-terra", .default = .medium, .max = true },
        .{ .model = "gpt-5.6-luna", .default = .medium, .max = true },
        .{ .model = "gpt-5.5", .default = .medium, .max = false },
    }) |case| {
        try std.testing.expectEqual(@as(?protocol.ReasoningEffort, case.default), defaultReasoningEffort(case.model));
        for ([_]protocol.ReasoningEffort{ .low, .medium, .high, .xhigh }) |effort|
            try std.testing.expect(supportsReasoningEffort(case.model, effort));
        try std.testing.expectEqual(case.max, supportsReasoningEffort(case.model, .max));
        try std.testing.expect(!supportsReasoningEffort(case.model, .none));
    }
    for ([_][]const u8{ "model-a", "gpt-6-luna-alias", "GPT-6-LUNA", "gpt-6-lun" }) |unknown| {
        try std.testing.expectEqual(@as(?protocol.ReasoningEffort, null), defaultReasoningEffort(unknown));
        inline for (std.meta.tags(protocol.ReasoningEffort)) |effort|
            try std.testing.expect(!supportsReasoningEffort(unknown, effort));
    }
    try std.testing.expect(std.meta.stringToEnum(protocol.ReasoningEffort, "ultra") == null);
}
