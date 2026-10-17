const protocol = @import("protocol.zig");
const provider_selection = @import("provider_selection.zig");

// The Codex adapter's local capability, independent of transport or credentials.
pub const provider_label = "codex";
pub const recommended_model = "gpt-6-luna";

pub const CompactionPolicy = struct {
    compaction_trigger: ?u64,
    output_reservation: u64,
};

/// Reservation is extra heuristic headroom, never a provider output limit.
pub fn compactionPolicy(model: []const u8, trigger_override: ?u64, reservation_override: ?u64) CompactionPolicy {
    const std = @import("std");
    // Codex metadata 21c16161191ff965031d1ac41fe9046011610743:
    // exact requested model, 272000 context tokens at 90 percent.
    return .{
        .compaction_trigger = trigger_override orelse if (std.mem.eql(u8, model, "gpt-6-luna")) @as(?u64, 244800) else null,
        .output_reservation = reservation_override orelse 0,
    };
}

/// Local identifier syntax, not a catalog, qualification or account entitlement.
pub fn validModel(model: []const u8) bool {
    if (model.len == 0 or model.len > protocol.max_model_bytes) return false;
    for (model) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

pub fn capability(readiness: provider_selection.Readiness) provider_selection.Capability {
    return .{ .name = provider_label, .recommended_model = recommended_model, .valid_model = validModel, .readiness = readiness };
}
