//! The Codex adapter's local capability, independent of transport or
//! credentials: identifier syntax, the effort grammar and one table of what
//! Rui knows about each release-supported model. Help text renders from the
//! table at compile time, so this module stays a functional core.
const std = @import("std");
const product_defaults = @import("product_defaults.zig");
const provider_name = @import("provider_name.zig");
const provider_selection = @import("provider_selection.zig");

/// Codex identifier syntax admits 1 to this many bytes.
pub const max_model_bytes = 256;

/// Rui's closed effort grammar. A model's catalog entry says which it accepts.
pub const ReasoningEffort = enum { none, low, medium, high, xhigh, max };

pub const CompactionPolicy = struct {
    compaction_trigger: ?u64,
    output_reservation: u64,
};

/// What Rui knows about one release-supported model. Every per-model rule
/// reads a row; an ID without a row has no inferred capability.
pub const Model = struct {
    id: []const u8,
    /// Catalog default when a Session sets no override.
    default_effort: ReasoningEffort,
    /// Whether the catalog advertises `max`. Every row advertises low through
    /// xhigh, and none advertises `none`.
    max_effort: bool,
    /// Tokens; the automatic compaction trigger is a percentage of it.
    context_window: u64,
};

/// Rui's release-supported models, not live account availability or
/// qualification. IDs are the visible models in OpenAI Codex's pinned catalog:
/// https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/models-manager/models.json
/// The other columns are exact values from Codex 970111f6cb62cc02fe36a82ea7d71b37a2889c97
/// models-manager/models.json, not backend effective effort or entitlement.
pub const models = [_]Model{
    .{ .id = "gpt-6-luna", .default_effort = .medium, .max_effort = true, .context_window = 272000 },
    .{ .id = "gpt-6.1-sol", .default_effort = .low, .max_effort = true, .context_window = 272000 },
    .{ .id = "gpt-6-sol", .default_effort = .medium, .max_effort = true, .context_window = 272000 },
    .{ .id = "gpt-6-astra", .default_effort = .low, .max_effort = true, .context_window = 272000 },
    .{ .id = "gpt-5.6-sol", .default_effort = .low, .max_effort = true, .context_window = 272000 },
    .{ .id = "gpt-5.6-terra", .default_effort = .medium, .max_effort = true, .context_window = 272000 },
    .{ .id = "gpt-5.6-luna", .default_effort = .medium, .max_effort = true, .context_window = 272000 },
    .{ .id = "gpt-5.5", .default_effort = .medium, .max_effort = false, .context_window = 272000 },
};

comptime {
    if (find(product_defaults.recommended_model) == null) @compileError("the recommended model needs a row in the model table");
}

/// Exact and case-sensitive, without aliases, prefixes or family inference.
pub fn find(model: []const u8) ?*const Model {
    for (&models) |*row| if (std.mem.eql(u8, row.id, model)) return row;
    return null;
}

/// Release support, which the CLI checks before new-Session creation or an
/// explicit default-model save. Selection syntax is `validModelSyntax`.
pub fn supportsModel(model: []const u8) bool {
    return find(model) != null;
}

/// Every user-facing list of supported IDs renders this text.
pub const model_help = blk: {
    var text: []const u8 = "Supported model IDs: ";
    for (models, 0..) |row, index| text = text ++ (if (index == 0) "" else ", ") ++ row.id;
    break :blk text ++ "\n";
};

/// The supported IDs without `max`, comma separated; empty when every row has it.
pub const ids_without_max_effort = blk: {
    var text: []const u8 = "";
    for (models) |row| {
        if (!row.max_effort) text = text ++ (if (text.len == 0) "" else ", ") ++ row.id;
    }
    break :blk text;
};

/// Unknown bindings have no inferred default.
pub fn defaultReasoningEffort(model: []const u8) ?ReasoningEffort {
    return if (find(model)) |row| row.default_effort else null;
}

/// Configuration admission intersects Rui's closed grammar with the pinned
/// model's advertised values. Frozen Operations do not consult this again.
pub fn supportsReasoningEffort(model: []const u8, effort: ReasoningEffort) bool {
    const row = find(model) orelse return false;
    return switch (effort) {
        .none => false,
        .max => row.max_effort,
        .low, .medium, .high, .xhigh => true,
    };
}

/// No alias inference, account entitlement or live qualification is implied.
/// Reservation is extra heuristic headroom, never a provider output limit.
pub fn compactionPolicy(model: []const u8, trigger_override: ?u64, reservation_override: ?u64) CompactionPolicy {
    const automatic: ?u64 = if (find(model)) |row|
        row.context_window * product_defaults.compaction_trigger_percent / 100
    else
        null;
    return .{
        .compaction_trigger = trigger_override orelse automatic,
        .output_reservation = reservation_override orelse product_defaults.output_reservation,
    };
}

/// Local identifier syntax, not a catalog, qualification or account entitlement.
pub fn validModelSyntax(model: []const u8) bool {
    if (model.len == 0 or model.len > max_model_bytes) return false;
    for (model) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

const provider_count = @typeInfo(provider_name.Provider).@"enum".field_names.len;

/// Every built-in provider, in declaration order. They share one catalog.
/// Selection of a Session binding or saved pin admits any exact ID with valid
/// syntax, including IDs this release does not list.
pub fn capabilities(readiness: *const provider_selection.Readinesses) [provider_count]provider_selection.Capability {
    return withPolicy(readiness, validModelSyntax);
}

/// Selection as `rui defaults inspect` predicts it for the next new Session,
/// which the CLI admits only with a release-supported model.
pub fn supportedCapabilities(readiness: *const provider_selection.Readinesses) [provider_count]provider_selection.Capability {
    return withPolicy(readiness, supportsModel);
}

fn withPolicy(readiness: *const provider_selection.Readinesses, admits: *const fn ([]const u8) bool) [provider_count]provider_selection.Capability {
    var out: [provider_count]provider_selection.Capability = undefined;
    for (&out, std.enums.values(provider_name.Provider)) |*entry, provider|
        entry.* = .{ .name = @tagName(provider), .recommended_model = product_defaults.recommended_model, .admits_model = admits, .readiness = readiness.get(provider) };
    return out;
}

test "supported model compaction defaults and exact identifier boundary" {
    for (models) |row| {
        const policy = compactionPolicy(row.id, null, null);
        try std.testing.expectEqual(@as(?u64, 244800), policy.compaction_trigger);
        try std.testing.expectEqual(@as(u64, 0), policy.output_reservation);
        const overridden = compactionPolicy(row.id, 7, 3);
        try std.testing.expectEqual(@as(?u64, 7), overridden.compaction_trigger);
        try std.testing.expectEqual(@as(u64, 3), overridden.output_reservation);
    }
    for ([_][]const u8{ "model-a", "gpt-6-luna-alias", "GPT-6-LUNA", "gpt-6-lun" }) |other| {
        try std.testing.expectEqual(@as(?u64, null), compactionPolicy(other, null, null).compaction_trigger);
        try std.testing.expect(!supportsModel(other));
    }
    try std.testing.expectEqual(@as(?u64, 11), compactionPolicy("model-a", 11, null).compaction_trigger);
}

test "reasoning effort uses exact catalog defaults and model support without expanding grammar" {
    for ([_]struct { model: []const u8, default: ReasoningEffort, max: bool }{
        .{ .model = "gpt-6-luna", .default = .medium, .max = true },
        .{ .model = "gpt-6.1-sol", .default = .low, .max = true },
        .{ .model = "gpt-6-sol", .default = .medium, .max = true },
        .{ .model = "gpt-6-astra", .default = .low, .max = true },
        .{ .model = "gpt-5.6-sol", .default = .low, .max = true },
        .{ .model = "gpt-5.6-terra", .default = .medium, .max = true },
        .{ .model = "gpt-5.6-luna", .default = .medium, .max = true },
        .{ .model = "gpt-5.5", .default = .medium, .max = false },
    }, models) |case, row| {
        try std.testing.expectEqualStrings(case.model, row.id);
        try std.testing.expect(supportsModel(case.model));
        try std.testing.expectEqual(@as(?ReasoningEffort, case.default), defaultReasoningEffort(case.model));
        for ([_]ReasoningEffort{ .low, .medium, .high, .xhigh }) |effort|
            try std.testing.expect(supportsReasoningEffort(case.model, effort));
        try std.testing.expectEqual(case.max, supportsReasoningEffort(case.model, .max));
        try std.testing.expect(!supportsReasoningEffort(case.model, .none));
    }
    for ([_][]const u8{ "model-a", "gpt-6-luna-alias", "GPT-6-LUNA", "gpt-6-lun" }) |unknown| {
        try std.testing.expectEqual(@as(?ReasoningEffort, null), defaultReasoningEffort(unknown));
        inline for (std.meta.tags(ReasoningEffort)) |effort|
            try std.testing.expect(!supportsReasoningEffort(unknown, effort));
    }
    try std.testing.expect(std.meta.stringToEnum(ReasoningEffort, "ultra") == null);
    try std.testing.expectEqualStrings("gpt-5.5", ids_without_max_effort);
    try std.testing.expectEqualStrings("Supported model IDs: gpt-6-luna, gpt-6.1-sol, gpt-6-sol, gpt-6-astra, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5\n", model_help);
}

test "selection syntax and release support stay distinct" {
    var readiness: provider_selection.Readinesses = .initFill(.missing);
    readiness.set(.codex, .configured);
    const syntax = capabilities(&readiness);
    const supported = supportedCapabilities(&readiness);
    try std.testing.expectEqualStrings("family=variant", (try provider_selection.resolve(&syntax, null, "family=variant", null, null)).selected.model);
    try std.testing.expectError(error.UnsupportedSelectionModel, provider_selection.resolve(&supported, null, "family=variant", null, null));
    try std.testing.expectEqualStrings(product_defaults.recommended_model, (try provider_selection.resolve(&supported, null, null, null, null)).selected.model);
    try std.testing.expectError(error.UnsupportedSelectionModel, provider_selection.resolve(&supported, null, null, "codex", "stale-pin"));
}

test "every built-in provider is selectable by its label, and two ready ones ask for a choice" {
    var readiness: provider_selection.Readinesses = .initFill(.configured);
    const both = capabilities(&readiness);
    try std.testing.expectEqual(provider_selection.Selection.chooser, try provider_selection.resolve(&both, null, null, null, null));
    try std.testing.expectEqualStrings("openai", (try provider_selection.resolve(&both, "openai", null, null, null)).selected.provider);
    readiness.set(.codex, .missing);
    const one = capabilities(&readiness);
    try std.testing.expectEqualStrings("openai", (try provider_selection.resolve(&one, null, null, null, null)).selected.provider);
}
