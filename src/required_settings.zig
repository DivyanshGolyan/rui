//! Which settings a new Session still lacks. Every creation path (configure, a creating Message, and
//! start_agent through them) asks this one owner, so a refusal names every missing setting at once.
const std = @import("std");
const connection = @import("connection.zig");
const provider_route = @import("provider_route.zig");
const product_defaults = @import("product_defaults.zig");

/// A setting a new Session must end up with. The stored bit of each is `1 << value`, so the
/// values are part of the Store format.
pub const Setting = enum(u2) {
    model = 0,
    workspace = 1,
    connection = 2,
};

/// A non-empty set of missing settings, listed in `Setting` order.
pub const Missing = struct {
    bits: u3,

    pub const all: Missing = .{ .bits = 0b111 };

    /// The saved column value: 1 through 7. Anything else is a corrupt Store.
    pub fn fromStored(value: u64) error{CorruptStore}!Missing {
        if (value == 0 or value > 0b111) return error.CorruptStore;
        return .{ .bits = @intCast(value) };
    }

    pub fn stored(self: Missing) u8 {
        return self.bits;
    }

    pub fn contains(self: Missing, setting: Setting) bool {
        return self.bits & bit(setting) != 0;
    }

    pub fn count(self: Missing) usize {
        return @popCount(self.bits);
    }

    pub fn iterator(self: Missing) Iterator {
        return .{ .rest = self.bits };
    }

    pub const Iterator = struct {
        rest: u3,

        pub fn next(self: *Iterator) ?Setting {
            if (self.rest == 0) return null;
            const value: u2 = @intCast(@ctz(self.rest));
            self.rest &= self.rest - 1;
            return @fromBackingInt(@intCast(value));
        }
    };

    /// `["model","workspace"]`, the wire's `missing` list.
    pub fn writeJson(self: Missing, out: *std.Io.Writer) !void {
        try out.writeByte('[');
        var settings = self.iterator();
        var first = true;
        while (settings.next()) |setting| {
            if (!first) try out.writeByte(',');
            first = false;
            try out.print("\"{s}\"", .{@tagName(setting)});
        }
        try out.writeByte(']');
    }

    pub const max_json_bytes = "[\"model\",\"workspace\",\"connection\"]".len;

    /// Reads the wire list back: one to three distinct setting names.
    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Missing {
        _ = allocator;
        _ = options;
        if (try source.next() != .array_begin) return error.UnexpectedToken;
        var bits: u3 = 0;
        while (true) {
            switch (try source.next()) {
                .array_end => break,
                .string => |name| {
                    const setting = std.meta.stringToEnum(Setting, name) orelse return error.InvalidEnumTag;
                    if (bits & bit(setting) != 0) return error.DuplicateField;
                    bits |= bit(setting);
                },
                else => return error.UnexpectedToken,
            }
        }
        if (bits == 0) return error.LengthMismatch;
        return .{ .bits = bits };
    }
};

fn bit(setting: Setting) u3 {
    return @as(u3, 1) << @backingInt(setting);
}

/// What a creation request brings. `parent` supplies workspace and provider by inheritance.
pub const Creation = struct {
    model: bool,
    workspace: bool,
    parent: bool,
    /// The provider the request names, or the parent's when `parent` is set.
    provider: ?connection.Name,
    served: *const provider_route.Served,
};

pub const Outcome = union(enum) {
    missing: Missing,
    complete: struct { provider: connection.Name },
};

pub fn check(creation: Creation) Outcome {
    var bits: u3 = 0;
    if (!creation.model) bits |= bit(.model);
    if (!creation.workspace and !creation.parent) bits |= bit(.workspace);
    const provider = resolveProvider(creation.provider, creation.served);
    if (provider == null) bits |= bit(.connection);
    if (bits != 0) return .{ .missing = .{ .bits = bits } };
    return .{ .complete = .{ .provider = provider.? } };
}

/// The provider a new Session gets: the named one, else the only served one, else the product
/// default when the Host serves none. Null when the Host serves several and none was named.
pub fn resolveProvider(named: ?connection.Name, served: *const provider_route.Served) ?connection.Name {
    if (named) |provider| return provider;
    var selected: ?connection.Name = null;
    for (served.items()) |entry| {
        if (selected != null) return null;
        selected = entry.name;
    }
    return selected orelse comptime connection.Name.parse(product_defaults.provider).?;
}

test "check names every missing setting over model, workspace, parent, provider and served providers" {
    const none: provider_route.Served = .{};
    var one: provider_route.Served = .{};
    try one.put(provider_route.builtIn(.openai, .key_file));
    var two = one;
    try two.put(provider_route.builtIn(.codex, .endpoint));
    const Set = enum { none, one, two };
    const Case = struct { model: bool, workspace: bool, parent: bool, provider: ?connection.Name, served: Set, expected: []const u8 };
    // Expected values are literals: a missing list, or "ok:<provider>".
    const cases = [_]Case{
        .{ .model = true, .workspace = true, .parent = false, .provider = null, .served = .none, .expected = "ok:codex" },
        .{ .model = true, .workspace = true, .parent = false, .provider = null, .served = .one, .expected = "ok:openai" },
        .{ .model = true, .workspace = true, .parent = false, .provider = null, .served = .two, .expected = "[\"connection\"]" },
        .{ .model = true, .workspace = true, .parent = false, .provider = connection.Name.parse("chatgpt").?, .served = .two, .expected = "ok:chatgpt" },
        .{ .model = true, .workspace = true, .parent = false, .provider = connection.Name.parse("chatgpt").?, .served = .none, .expected = "ok:chatgpt" },
        .{ .model = true, .workspace = false, .parent = false, .provider = null, .served = .one, .expected = "[\"workspace\"]" },
        .{ .model = true, .workspace = false, .parent = true, .provider = connection.Name.parse("codex").?, .served = .two, .expected = "ok:codex" },
        .{ .model = true, .workspace = true, .parent = true, .provider = connection.Name.parse("openai").?, .served = .none, .expected = "ok:openai" },
        .{ .model = false, .workspace = true, .parent = false, .provider = null, .served = .one, .expected = "[\"model\"]" },
        .{ .model = false, .workspace = false, .parent = true, .provider = connection.Name.parse("codex").?, .served = .two, .expected = "[\"model\"]" },
        .{ .model = false, .workspace = false, .parent = false, .provider = null, .served = .none, .expected = "[\"model\",\"workspace\"]" },
        .{ .model = false, .workspace = true, .parent = false, .provider = null, .served = .two, .expected = "[\"model\",\"connection\"]" },
        .{ .model = true, .workspace = false, .parent = false, .provider = null, .served = .two, .expected = "[\"workspace\",\"connection\"]" },
        .{ .model = false, .workspace = false, .parent = false, .provider = null, .served = .two, .expected = "[\"model\",\"workspace\",\"connection\"]" },
        .{ .model = false, .workspace = false, .parent = false, .provider = connection.Name.parse("openai").?, .served = .two, .expected = "[\"model\",\"workspace\"]" },
    };
    for (cases) |case| {
        var buffer: [64]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        switch (check(.{ .model = case.model, .workspace = case.workspace, .parent = case.parent, .provider = case.provider, .served = switch (case.served) {
            .none => &none,
            .one => &one,
            .two => &two,
        } })) {
            .missing => |missing| {
                try missing.writeJson(&out);
                try std.testing.expect(missing.count() >= 1);
            },
            .complete => |complete| try out.print("ok:{s}", .{complete.provider.slice()}),
        }
        try std.testing.expectEqualStrings(case.expected, out.buffered());
    }
}

test "the stored missing set is 1 through 7 and lists settings in setting order" {
    try std.testing.expectError(error.CorruptStore, Missing.fromStored(0));
    try std.testing.expectError(error.CorruptStore, Missing.fromStored(8));
    for (1..8) |value| {
        const missing = try Missing.fromStored(value);
        try std.testing.expectEqual(@as(u8, @intCast(value)), missing.stored());
        var settings = missing.iterator();
        var previous: ?Setting = null;
        var seen: usize = 0;
        while (settings.next()) |setting| : (seen += 1) {
            try std.testing.expect(missing.contains(setting));
            if (previous) |earlier| try std.testing.expect(@backingInt(earlier) < @backingInt(setting));
            previous = setting;
        }
        try std.testing.expectEqual(missing.count(), seen);
    }
    try std.testing.expectEqual(@as(u8, 1), (Missing{ .bits = 0b001 }).stored());
    try std.testing.expect((Missing{ .bits = 0b100 }).contains(.connection));
    var buffer: [Missing.max_json_bytes]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try Missing.all.writeJson(&out);
    try std.testing.expectEqualStrings("[\"model\",\"workspace\",\"connection\"]", out.buffered());
    for (1..8) |value| {
        const missing = try Missing.fromStored(value);
        var json: [Missing.max_json_bytes]u8 = undefined;
        var written: std.Io.Writer = .fixed(&json);
        try missing.writeJson(&written);
        const parsed = try std.json.parseFromSlice(Missing, std.testing.allocator, written.buffered(), .{});
        defer parsed.deinit();
        try std.testing.expectEqual(missing.bits, parsed.value.bits);
    }
    for ([_][]const u8{ "[]", "[\"model\",\"model\"]", "[\"skills\"]", "{}", "[1]" }) |bad|
        try std.testing.expect(std.meta.isError(std.json.parseFromSlice(Missing, std.testing.allocator, bad, .{})));
}
