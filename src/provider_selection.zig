const std = @import("std");

pub const Readiness = enum { configured, missing, refresh_required, credential_error };

pub const Capability = struct {
    name: []const u8,
    recommended_model: []const u8,
    models: []const []const u8,
    readiness: Readiness,
};

pub fn codex(readiness: Readiness) Capability {
    return .{ .name = "codex", .recommended_model = "gpt-6-luna", .models = &.{"gpt-6-luna"}, .readiness = readiness };
}

pub const Selection = union(enum) {
    chooser,
    selected: struct {
        provider: []const u8,
        model: []const u8,
        readiness: Readiness,
    },
};

/// Borrowed capability/preference strings. This resolves only a prospective new
/// Session; callers must never apply its answer to an existing Session binding.
pub fn resolve(capabilities: []const Capability, explicit_provider: ?[]const u8, explicit_model: ?[]const u8, saved_provider: ?[]const u8, saved_model: ?[]const u8) !Selection {
    var chosen = explicit_provider orelse saved_provider;
    if (chosen == null) {
        for (capabilities) |capability| {
            if (capability.readiness != .configured) continue;
            if (chosen != null) return .chooser;
            chosen = capability.name;
        }
    }
    const name = chosen orelse return .chooser;
    for (capabilities) |capability| {
        if (!std.mem.eql(u8, name, capability.name)) continue;
        const model = explicit_model orelse (if (saved_provider != null and std.mem.eql(u8, name, saved_provider.?)) saved_model else null) orelse capability.recommended_model;
        for (capability.models) |supported| {
            if (std.mem.eql(u8, model, supported)) return .{ .selected = .{
                .provider = capability.name,
                .model = model,
                .readiness = capability.readiness,
            } };
        }
        return error.UnsupportedSelectionModel;
    }
    return error.UnsupportedSelectionProvider;
}

test "prospective selection does not fall back from a stale or unavailable preference" {
    const capabilities = [_]Capability{
        .{ .name = "codex", .recommended_model = "luna", .models = &.{ "luna", "other" }, .readiness = .configured },
        .{ .name = "synthetic", .recommended_model = "small", .models = &.{"small"}, .readiness = .configured },
    };
    try std.testing.expectEqual(Selection.chooser, try resolve(&.{}, null, null, null, null));
    try std.testing.expectEqual(Selection.chooser, try resolve(&capabilities, null, null, null, null));
    try std.testing.expectEqualStrings("synthetic", (try resolve(&capabilities, "synthetic", null, "codex", "other")).selected.provider);
    try std.testing.expectEqualStrings("small", (try resolve(&capabilities, "synthetic", null, "codex", "other")).selected.model);
    try std.testing.expectEqualStrings("other", (try resolve(&capabilities, null, null, "codex", "other")).selected.model);
    try std.testing.expectError(error.UnsupportedSelectionModel, resolve(&capabilities, null, null, "codex", "unknown"));
    try std.testing.expectError(error.UnsupportedSelectionProvider, resolve(&capabilities, null, null, "removed", null));
    try std.testing.expectError(error.UnsupportedSelectionModel, resolve(&capabilities, "synthetic", "luna", null, null));
    const only = capabilities[0..1];
    try std.testing.expectEqualStrings("luna", (try resolve(only, null, null, null, null)).selected.model);
    const missing = [_]Capability{.{ .name = "codex", .recommended_model = "luna", .models = &.{"luna"}, .readiness = .missing }};
    try std.testing.expectEqual(Selection.chooser, try resolve(&missing, null, null, null, null));
    try std.testing.expectEqual(Readiness.missing, (try resolve(&missing, null, null, "codex", null)).selected.readiness);
    try std.testing.expectEqual(Readiness.missing, (try resolve(&missing, "codex", null, null, null)).selected.readiness);
}
