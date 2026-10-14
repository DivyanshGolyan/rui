const std = @import("std");
const preferences = @import("preference_values.zig");
const protocol = @import("protocol.zig");
const provider_selection = @import("provider_selection.zig");

/// Explicit arguments borrow invocation-lifetime storage, never preference bytes.
pub const Intent = struct {
    store: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,

    pub fn needsPreferences(self: Intent) bool {
        return self.store == null or self.provider == null or self.model == null;
    }
};

/// One observation of prospective defaults. Replace the whole snapshot after
/// external choice/login; no selected slice survives that replacement.
pub const Snapshot = struct {
    intent: Intent,
    defaults: preferences.Values,

    /// Borrows explicit arguments, this snapshot in final storage, or fallback.
    /// Native preflight must precede resolve; raw explicit paths stay unbounded
    /// here so their validation and errors remain with the native owner.
    pub fn destination(self: *const Snapshot, home: []const u8, fallback: []u8) !struct { path: []const u8, saved: bool } {
        if (self.intent.store) |path| return .{ .path = path, .saved = false };
        if (self.defaults.store.len != 0) return .{ .path = self.defaults.store.slice(), .saved = true };
        return .{ .path = try preferences.defaultStore(home, fallback), .saved = false };
    }

    /// Null requires choice/repair, not fallback. Readiness is advisory: the CLI
    /// still checks the actual Host and captures its atomic require_model guard.
    pub fn resolve(self: *const Snapshot, readiness: provider_selection.Readiness) !?Binding {
        const selection = try provider_selection.resolve(
            &.{provider_selection.codex(readiness)},
            self.intent.provider,
            self.intent.model,
            if (self.defaults.provider.len == 0) null else self.defaults.provider.slice(),
            if (self.defaults.model.len == 0) null else self.defaults.model.slice(),
        );
        if (selection == .chooser or !selection.selected.readiness.usable()) return null;
        var binding: Binding = .{};
        try binding.provider.set(selection.selected.provider);
        try binding.model.set(selection.selected.model);
        return binding;
    }
};

/// Owns bytes, including a saved model pin. Safe to move or retain after the
/// snapshot changes; take slices only after placing the binding in final storage.
pub const Binding = struct {
    provider: protocol.Bounded(16) = .{},
    model: protocol.Bounded(protocol.max_model_bytes) = .{},
};

test "new Session preference dependency and refreshed choices with every explicit subset" {
    for (0..8) |mask| {
        const intent: Intent = .{
            .store = if (mask & 1 != 0) "/explicit" else null,
            .provider = if (mask & 2 != 0) "codex" else null,
            .model = if (mask & 4 != 0) "explicit-model" else null,
        };
        try std.testing.expectEqual(mask != 7, intent.needsPreferences());
        var defaults: preferences.Values = .{};
        try defaults.provider.set("codex");
        var fallback: [128]u8 = undefined;
        for ([_][2][]const u8{ .{ "/before", "before-model" }, .{ "/changed-after-choice", "after" } }) |values| {
            try defaults.store.set(values[0]);
            try defaults.model.set(values[1]);
            const snapshot: Snapshot = .{ .intent = intent, .defaults = if (intent.needsPreferences()) defaults else .{} };
            const destination = try snapshot.destination("/home/test", &fallback);
            try std.testing.expectEqualStrings(if (mask & 1 != 0) "/explicit" else values[0], destination.path);
            try std.testing.expectEqual(mask & 1 == 0, destination.saved);
            const binding = (try snapshot.resolve(.configured)).?;
            try std.testing.expectEqualStrings("codex", binding.provider.slice());
            try std.testing.expectEqualStrings(if (mask & 4 != 0) "explicit-model" else values[1], binding.model.slice());
        }
    }
}

test "new Session refresh owns bindings and selects shorter and longer saved destinations" {
    for ([_][2][]const u8{
        .{ "/long-before-choice", "/s" },
        .{ "/s", "/a-much-longer-after-choice" },
    }) |paths| {
        var source: preferences.Values = .{};
        try source.store.set(paths[0]);
        try source.provider.set("codex");
        try source.model.set("before-choice-model");
        var snapshot: Snapshot = .{ .intent = .{}, .defaults = source };
        var fallback: [128]u8 = undefined;
        const before = try snapshot.destination("/home/test", &fallback);
        try std.testing.expect(before.saved);
        try std.testing.expectEqualStrings(paths[0], before.path);
        try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolve(.missing));
        const retained = (try snapshot.resolve(.configured)).?;

        // External work replaces defaults; the old snapshot and binding cannot
        // borrow the load buffer, and the new selection must use the new bytes.
        try source.store.set(paths[1]);
        try source.model.set("after");
        try std.testing.expectEqualStrings(paths[0], (try snapshot.destination("/home/test", &fallback)).path);
        snapshot = .{ .intent = .{}, .defaults = source };
        const after = try snapshot.destination("/home/test", &fallback);
        try std.testing.expect(after.saved);
        try std.testing.expectEqualStrings(paths[1], after.path);
        const selected = (try snapshot.resolve(.renewal_due)).?;
        snapshot.defaults = .{};
        try std.testing.expectEqualStrings("codex", selected.provider.slice());
        try std.testing.expectEqualStrings("after", selected.model.slice());
        try std.testing.expectEqualStrings("before-choice-model", retained.model.slice());
    }
}

test "new Session explicit choices bypass stale defaults without destination fallback" {
    var snapshot: Snapshot = .{ .intent = .{}, .defaults = .{} };
    try snapshot.defaults.store.set("/unavailable-saved-store");
    try snapshot.defaults.provider.set("removed");
    try snapshot.defaults.model.set("stale-model");
    var fallback: [128]u8 = undefined;
    const saved = try snapshot.destination("/home/test", &fallback);
    try std.testing.expect(saved.saved);
    try std.testing.expectEqualStrings("/unavailable-saved-store", saved.path);
    try std.testing.expectError(error.UnsupportedSelectionProvider, snapshot.resolve(.configured));
    snapshot.intent = .{ .store = "/explicit", .provider = "codex", .model = "explicit-model" };
    try std.testing.expect(!snapshot.intent.needsPreferences());
    const explicit = try snapshot.destination("/unused", &fallback);
    try std.testing.expect(!explicit.saved);
    try std.testing.expectEqualStrings("/explicit", explicit.path);
    for ([_]provider_selection.Readiness{ .missing, .refresh_required, .credential_error }) |state|
        try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolve(state));
    try std.testing.expectEqualStrings("explicit-model", (try snapshot.resolve(.renewal_due)).?.model.slice());
    snapshot.intent.model = null;
    try std.testing.expectEqualStrings("gpt-6-luna", (try snapshot.resolve(.configured)).?.model.slice());
    snapshot.defaults = .{};
    snapshot.intent = .{};
    const home = try snapshot.destination("/home/test", &fallback);
    try std.testing.expect(!home.saved);
    try std.testing.expectEqualStrings("/home/test/.local/share/rui/store", home.path);
    try std.testing.expectEqual(@as(?Binding, null), try snapshot.resolve(.missing));
    try std.testing.expectEqualStrings("gpt-6-luna", (try snapshot.resolve(.renewal_due)).?.model.slice());
    snapshot.intent.model = "bad model";
    try std.testing.expectError(error.UnsupportedSelectionModel, snapshot.resolve(.configured));

    // Destination validation belongs to native preflight, even when the same
    // invocation also has an unsupported provider/model or an invalid HOME.
    const long_raw_path = [_]u8{'x'} ** (std.Io.Dir.max_path_bytes + 1);
    snapshot.intent.store = &long_raw_path;
    try std.testing.expectEqualStrings(&long_raw_path, (try snapshot.destination("relative-home", &fallback)).path);
    snapshot.intent.store = null;
    try std.testing.expectError(error.InvalidHome, snapshot.destination("relative-home", &fallback));
}
