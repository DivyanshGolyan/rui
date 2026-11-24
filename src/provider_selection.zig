const std = @import("std");
const connection = @import("connection.zig");
const provider_route = @import("provider_route.zig");
const connection_names = @import("connection_names.zig");

pub const Readiness = enum {
    configured,
    renewal_due,
    missing,
    refresh_required,
    credential_error,

    pub fn usable(self: Readiness) bool {
        return self == .configured or self == .renewal_due;
    }
};

/// The readiness of each served name: the built-in providers first, in their fixed
/// order, then key connections in document order. A name that is not served reads as missing.
pub const Readinesses = struct {
    map: connection_names.NameArray(Readiness) = .{},

    pub fn initFill(state: Readiness) Readinesses {
        var result: Readinesses = .{};
        for (provider_route.built_in_names) |name| result.map.set(name, state) catch unreachable;
        return result;
    }

    pub fn get(self: *const Readinesses, name: connection.Name) Readiness {
        return self.map.get(name) orelse .missing;
    }

    /// Sets a name's readiness, adding the name if it is not yet served.
    pub fn set(self: *Readinesses, name: connection.Name, state: Readiness) void {
        self.map.set(name, state) catch unreachable;
    }

    /// The served names, in order.
    pub fn names(self: *const Readinesses) []const connection.Name {
        return self.map.names[0..self.map.len];
    }

    /// The readiness of each served name, in the same order as `names`.
    pub fn states(self: *const Readinesses) []const Readiness {
        return self.map.values[0..self.map.len];
    }
};

pub const Capability = struct {
    name: []const u8,
    recommended_model: []const u8,
    admits_model: *const fn ([]const u8) bool,
    readiness: Readiness,
};

pub const Selection = union(enum) {
    chooser,
    selected: struct {
        provider: []const u8,
        model: []const u8,
        readiness: Readiness,
    },
};

pub fn resolve(capabilities: []const Capability, explicit_provider: ?[]const u8, explicit_model: ?[]const u8, saved_provider: ?[]const u8, saved_model: ?[]const u8) !Selection {
    var chosen = explicit_provider orelse saved_provider;
    if (chosen == null) {
        for (capabilities) |capability| {
            if (!capability.readiness.usable()) continue;
            if (chosen != null) return .chooser;
            chosen = capability.name;
        }
    }
    const name = chosen orelse return .chooser;
    for (capabilities) |capability| {
        if (!std.mem.eql(u8, name, capability.name)) continue;
        const model = explicit_model orelse (if (saved_provider != null and std.mem.eql(u8, name, saved_provider.?)) saved_model else null) orelse capability.recommended_model;
        if (!capability.admits_model(model)) return error.UnsupportedSelectionModel;
        return .{ .selected = .{
            .provider = capability.name,
            .model = model,
            .readiness = capability.readiness,
        } };
    }
    return error.UnsupportedSelectionProvider;
}

test "prospective selection does not fall back from a stale or unavailable preference" {
    const Policy = struct {
        fn valid(model: []const u8) bool {
            return std.mem.eql(u8, model, "luna") or std.mem.eql(u8, model, "other");
        }
        fn small(model: []const u8) bool {
            return std.mem.eql(u8, model, "small");
        }
    };
    const capabilities = [_]Capability{
        .{ .name = "codex", .recommended_model = "luna", .admits_model = Policy.valid, .readiness = .configured },
        .{ .name = "synthetic", .recommended_model = "small", .admits_model = Policy.small, .readiness = .configured },
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
    const missing = [_]Capability{.{ .name = "codex", .recommended_model = "luna", .admits_model = Policy.valid, .readiness = .missing }};
    try std.testing.expectEqual(Selection.chooser, try resolve(&missing, null, null, null, null));
    try std.testing.expectEqual(Readiness.missing, (try resolve(&missing, null, null, "codex", null)).selected.readiness);
    try std.testing.expectEqual(Readiness.missing, (try resolve(&missing, "codex", null, null, null)).selected.readiness);
}

test "Codex selection accepts identifiers without claiming model qualification" {
    var readiness: Readinesses = .initFill(.configured);
    const capability = @import("model_capability.zig").capabilities(&readiness).slice()[0];
    try std.testing.expectEqualStrings("family=variant", (try resolve(&.{capability}, null, "family=variant", null, null)).selected.model);
    const maximum = @as([256]u8, @splat('x'));
    try std.testing.expectEqualStrings(&maximum, (try resolve(&.{capability}, null, &maximum, null, null)).selected.model);
    for ([_][]const u8{ "", "bad model", "bad\nmodel", "\x7f", "\xc3\xa9", &@as([257]u8, @splat('x')) }) |invalid|
        try std.testing.expectError(error.UnsupportedSelectionModel, resolve(&.{capability}, null, invalid, null, null));
}

test "renewal due selects a sole provider and resolves only absent model pins" {
    var readiness: Readinesses = .initFill(.renewal_due);
    var capability = @import("model_capability.zig").capabilities(&readiness).slice()[0];
    capability.recommended_model = "future-recommendation";
    const inherited = try resolve(&.{capability}, null, null, null, null);
    try std.testing.expect(inherited == .selected);
    try std.testing.expectEqualStrings("future-recommendation", inherited.selected.model);
    try std.testing.expectEqual(Readiness.renewal_due, inherited.selected.readiness);
    try std.testing.expectEqualStrings("explicit-pin", (try resolve(&.{capability}, null, null, "codex", "explicit-pin")).selected.model);
    for ([_]Readiness{ .missing, .refresh_required, .credential_error }) |unavailable| {
        capability.readiness = unavailable;
        try std.testing.expectEqual(Selection.chooser, try resolve(&.{capability}, null, null, null, null));
        try std.testing.expectEqual(unavailable, (try resolve(&.{capability}, null, null, "codex", null)).selected.readiness);
    }
}

test "Readinesses lists the built-ins first, then connections in order, and reads absent names as missing" {
    var readiness: Readinesses = .initFill(.configured);
    const built_ins = provider_route.built_in_names.len;
    try std.testing.expectEqual(built_ins, readiness.names().len);
    try std.testing.expectEqual(Readiness.missing, readiness.get(connection.Name.parse("alpha").?));
    readiness.set(connection.Name.parse("alpha").?, .missing);
    readiness.set(connection.Name.parse("beta").?, .configured);
    try std.testing.expectEqual(built_ins + 2, readiness.names().len);
    try std.testing.expectEqualStrings("alpha", readiness.names()[built_ins].slice());
    try std.testing.expectEqualStrings("beta", readiness.names()[built_ins + 1].slice());
    readiness.set(connection.Name.parse("beta").?, .refresh_required);
    try std.testing.expectEqual(built_ins + 2, readiness.names().len);
    try std.testing.expectEqual(Readiness.refresh_required, readiness.get(connection.Name.parse("beta").?));
}
