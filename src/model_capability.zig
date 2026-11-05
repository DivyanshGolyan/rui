//! Model capability derived only from the shipped catalog, independent of
//! transport, credentials, client defaults and account entitlement.
const std = @import("std");
const catalog = @import("model_catalog.zig");
const product_defaults = @import("product_defaults.zig");
const provider_name = @import("provider_name.zig");
const provider_selection = @import("provider_selection.zig");

pub const max_model_bytes = catalog.max_model_bytes;
pub const ReasoningEffort = catalog.ReasoningEffort;
pub const validModelSyntax = catalog.validModelSyntax;

pub const CompactionPolicy = struct {
    compaction_trigger: u64,
    output_reservation: u64,
};

/// Exact catalog membership, without aliases, prefixes or family inference.
pub fn supportsModel(model: []const u8) bool {
    return catalog.find(catalog.shipped, model) != null;
}

/// Every user-facing list of supported IDs renders this text.
pub const model_help = blk: {
    var text: []const u8 = "Supported model IDs: ";
    for (catalog.openai_ids, 0..) |id, index| text = text ++ (if (index == 0) "" else ", ") ++ id;
    break :blk text ++ "\n";
};

/// The supported IDs without `max`, comma separated; empty when every row has it.
pub const ids_without_max_effort = blk: {
    @setEvalBranchQuota(20000);
    var text: []const u8 = "";
    for (catalog.shipped) |row| {
        if (row.openai and !row.efforts.contains(.max)) text = text ++ (if (text.len == 0) "" else ", ") ++ row.id;
    }
    break :blk text;
};

/// Configuration admission intersects Rui's closed grammar with the pinned
/// model's advertised values. Frozen Operations do not consult this again.
pub fn supportsReasoningEffort(model: []const u8, effort: ReasoningEffort) bool {
    const row = catalog.find(catalog.shipped, model) orelse return false;
    return row.efforts.contains(effort);
}

/// The effort a new Session on `model` starts at from the saved one: the
/// saved one when the model offers it, else none. Client product defaults
/// apply separately.
pub fn startEffort(saved: ?ReasoningEffort, model: []const u8) ?ReasoningEffort {
    const effort = saved orelse return null;
    return if (supportsReasoningEffort(model, effort)) effort else null;
}

/// A model's context window: its row's, else the product's unlisted default.
pub fn contextWindow(model: []const u8) u64 {
    const row = catalog.find(catalog.shipped, model) orelse return product_defaults.unlisted_context_window;
    return row.context_window orelse product_defaults.unlisted_context_window;
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
    for (catalog.shipped) |row| {
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

test "reasoning effort uses exactly the catalog list without expanding grammar" {
    for (catalog.shipped) |row| {
        try std.testing.expect(supportsModel(row.id));
        try std.testing.expectEqual(@as(u64, row.context_window orelse product_defaults.unlisted_context_window), contextWindow(row.id));
        inline for (std.meta.tags(ReasoningEffort)) |effort|
            try std.testing.expectEqual(row.efforts.contains(effort), supportsReasoningEffort(row.id, effort));
    }
    try std.testing.expectEqual(@as(u64, 1050000), contextWindow("gpt-6.1-sol"));
    for ([_]ReasoningEffort{ .low, .medium, .high, .xhigh, .max }) |effort|
        try std.testing.expect(supportsReasoningEffort("gpt-6.1-sol", effort));
    try std.testing.expect(!supportsReasoningEffort("gpt-6.1-sol", .none));
    try std.testing.expect(supportsReasoningEffort("gpt-6.1-terra", .none));
    try std.testing.expect(!supportsReasoningEffort("gpt-5.5", .max));
    for ([_][]const u8{ "model-a", "gpt-6-luna-alias", "GPT-6-LUNA", "gpt-6-lun" }) |unknown| {
        try std.testing.expect(!supportsModel(unknown));
        try std.testing.expectEqual(product_defaults.unlisted_context_window, contextWindow(unknown));
        inline for (std.meta.tags(ReasoningEffort)) |effort|
            try std.testing.expect(!supportsReasoningEffort(unknown, effort));
    }
    try std.testing.expect(std.meta.stringToEnum(ReasoningEffort, "ultra") == null);
}

test "model help lists only OpenAI catalog ids in catalog order" {
    var help: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer help.deinit();
    var exceptions: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer exceptions.deinit();
    try help.writer.writeAll("Supported model IDs: ");
    var count: usize = 0;
    var without_max: usize = 0;
    for (catalog.shipped) |row| if (row.openai) {
        try help.writer.print("{s}{s}", .{ if (count == 0) "" else ", ", row.id });
        try std.testing.expectEqualStrings(row.id, catalog.openai_ids[count]);
        count += 1;
        if (!row.efforts.contains(.max)) {
            try exceptions.writer.print("{s}{s}", .{ if (without_max == 0) "" else ", ", row.id });
            without_max += 1;
        }
    };
    try help.writer.writeByte('\n');
    try std.testing.expectEqual(count, catalog.openai_ids.len);
    try std.testing.expectEqualStrings(help.written(), model_help);
    try std.testing.expectEqualStrings(exceptions.written(), ids_without_max_effort);
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
