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
    compaction_trigger: u64,
    output_reservation: u64,
};

/// What Rui knows about one release-supported model. Every per-model rule
/// reads a row; an ID without a row has no inferred capability.
pub const Model = struct {
    id: []const u8,
    /// D111: the effort a client may choose when building a new spec.
    default_effort: ReasoningEffort,
    /// Whether the catalog advertises `max`. Every row advertises low through
    /// xhigh, and none advertises `none`.
    max_effort: bool,
    /// D166: the largest compactAt a spec may request for this model.
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
    // From Codex 5c0b1ac71f2f04016abdfcf43bee7e0c96867f0e models-manager/models.json,
    // until the shipped catalog (C1) replaces this table.
    .{ .id = "gpt-6.1-terra", .default_effort = .low, .max_effort = true, .context_window = 500000 },
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

/// Whether Rui's table lists the model, which then runs with its row's
/// limits; any other model with valid syntax runs with default limits.
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

/// The effort a new Session on `model` starts at from the saved one: the
/// saved one when the model offers it, else none, so the model's own
/// default applies.
pub fn startEffort(saved: ?ReasoningEffort, model: []const u8) ?ReasoningEffort {
    const effort = saved orelse return null;
    return if (supportsReasoningEffort(model, effort)) effort else null;
}

/// A model's context window: its row's, else the product's unlisted default.
pub fn contextWindow(model: []const u8) u64 {
    return if (find(model)) |row| row.context_window else product_defaults.unlisted_context_window;
}

/// No alias inference, account entitlement or live qualification is implied.
/// Reservation is extra heuristic headroom, never a provider output limit.
pub fn compactionPolicy(model: []const u8, trigger_override: ?u64, reservation_override: ?u64) CompactionPolicy {
    // D111: a stored null setting has fixed headroom, not a catalog default.
    // New specs always save their explicit token count.
    _ = model;
    return .{
        .compaction_trigger = trigger_override orelse product_defaults.unlisted_context_window * product_defaults.compaction_trigger_percent / 100,
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
/// syntax, including IDs this release does not list, which run with default
/// limits.
pub fn capabilities(readiness: *const provider_selection.Readinesses) [provider_count]provider_selection.Capability {
    var out: [provider_count]provider_selection.Capability = undefined;
    for (&out, std.enums.values(provider_name.Provider)) |*entry, provider|
        entry.* = .{ .name = @tagName(provider), .recommended_model = product_defaults.recommended_model, .admits_model = validModelSyntax, .readiness = readiness.get(provider) };
    return out;
}

test "compaction policy never infers a spec from the model catalog" {
    for (models) |row| {
        const policy = compactionPolicy(row.id, null, null);
        const expected: u64 = 115200;
        try std.testing.expectEqual(expected, policy.compaction_trigger);
        try std.testing.expectEqual(@as(u64, 0), policy.output_reservation);
        const overridden = compactionPolicy(row.id, 7, 3);
        try std.testing.expectEqual(@as(u64, 7), overridden.compaction_trigger);
        try std.testing.expectEqual(@as(u64, 3), overridden.output_reservation);
    }
    for ([_][]const u8{ "model-a", "gpt-6-luna-alias", "GPT-6-LUNA", "gpt-6-lun" }) |other| {
        // D111: stored null values use the same fixed threshold on every model.
        try std.testing.expectEqual(@as(u64, 115200), compactionPolicy(other, null, null).compaction_trigger);
        try std.testing.expect(!supportsModel(other));
    }
    try std.testing.expectEqual(@as(u64, 11), compactionPolicy("model-a", 11, null).compaction_trigger);
}

test "reasoning effort uses exact catalog defaults and model support without expanding grammar" {
    for ([_]struct { model: []const u8, default: ReasoningEffort, max: bool }{
        .{ .model = "gpt-6-luna", .default = .medium, .max = true },
        .{ .model = "gpt-6.1-sol", .default = .low, .max = true },
        .{ .model = "gpt-6.1-terra", .default = .low, .max = true },
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
    try std.testing.expectEqualStrings("Supported model IDs: gpt-6-luna, gpt-6.1-sol, gpt-6.1-terra, gpt-6-sol, gpt-6-astra, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5\n", model_help);
}

test "a new Session starts at the saved effort only when its model offers it" {
    try std.testing.expectEqual(@as(?ReasoningEffort, .max), startEffort(.max, "gpt-6-luna"));
    try std.testing.expectEqual(@as(?ReasoningEffort, null), startEffort(.max, "gpt-5.5"));
    try std.testing.expectEqual(@as(?ReasoningEffort, null), startEffort(.max, "unlisted-model"));
    try std.testing.expectEqual(@as(?ReasoningEffort, null), startEffort(null, "gpt-6-luna"));
}

test "selection admits any ID with valid syntax, listed or not" {
    var readiness: provider_selection.Readinesses = .initFill(.missing);
    readiness.set(.codex, .configured);
    const selectable = capabilities(&readiness);
    try std.testing.expectEqualStrings("family=variant", (try provider_selection.resolve(&selectable, null, "family=variant", null, null)).selected.model);
    try std.testing.expectEqualStrings("stale-pin", (try provider_selection.resolve(&selectable, null, null, "codex", "stale-pin")).selected.model);
    try std.testing.expectEqualStrings(product_defaults.recommended_model, (try provider_selection.resolve(&selectable, null, null, null, null)).selected.model);
    try std.testing.expectError(error.UnsupportedSelectionModel, provider_selection.resolve(&selectable, null, "bad model", null, null));
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
