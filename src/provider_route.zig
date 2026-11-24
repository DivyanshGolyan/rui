const std = @import("std");
const connection = @import("connection.zig");
const provider_name = @import("provider_name.zig");
const Provider = provider_name.Provider;

pub const Route = enum { unserved, endpoint, chatgpt_device, key_file, chatgpt_plan };

/// The most connections one Host serves at once.
pub const max_served = connection.max_list;

/// A served connection's label, as the Host shows it.
pub const Label = struct {
    bytes: [connection.max_label_bytes]u8 = @splat(0),
    len: u8 = 0,

    pub fn parse(text: []const u8) ?Label {
        if (text.len > connection.max_label_bytes) return null;
        var label: Label = .{ .len = @intCast(text.len) };
        @memcpy(label.bytes[0..text.len], text);
        return label;
    }

    pub fn slice(self: *const Label) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// One served connection: its name, label, how the Host reaches it, the wire
/// codec its Sessions speak, and whether it runs web_search.
pub const Entry = struct {
    name: connection.Name,
    label: Label,
    route: Route,
    codec: provider_name.Codec,
    web_search: bool,
};

/// The Host's served set, keyed by connection name. It lists only served
/// names, so an absent name is unserved. `of` is the one lookup that answers
/// "who serves this Session".
pub const Served = struct {
    entries: [max_served]Entry = undefined,
    len: usize = 0,

    pub fn put(self: *Served, entry: Entry) error{ServedFull}!void {
        if (self.len == max_served) return error.ServedFull;
        self.entries[self.len] = entry;
        self.len += 1;
    }

    pub fn items(self: *const Served) []const Entry {
        return self.entries[0..self.len];
    }

    pub fn of(self: *const Served, name: []const u8) ?*const Entry {
        for (self.items()) |*entry| if (std.mem.eql(u8, entry.name.slice(), name)) return entry;
        return null;
    }

    pub fn servesModel(self: *const Served) bool {
        return self.len != 0;
    }

    /// The route a name is served at, `unserved` when the name is absent.
    pub fn route(self: *const Served, name: []const u8) Route {
        return if (self.of(name)) |entry| entry.route else .unserved;
    }

    /// The codec of the binding named `name`: a served name's entry, else an absent built-in name's own
    /// codec, else none. The one owner of whether a name is a binding a Session may be created on.
    pub fn codecOf(self: *const Served, name: []const u8) ?provider_name.Codec {
        if (self.of(name)) |entry| return entry.codec;
        const built_in = builtInOf(connection.Name.parse(name) orelse return null) orelse return null;
        return built_in.codec();
    }

    /// Whether the binding named `name` runs the tool. This is the one owner of tool capability: a served
    /// name answers from its entry, an absent built-in name from the built-in provider's facts, and any
    /// other absent name runs nothing. Serving decides reachability, not what the binding can run.
    pub fn runsTool(self: *const Served, name: []const u8, tool: []const u8) bool {
        if (self.of(name)) |entry| return entry.web_search and std.mem.eql(u8, tool, "web_search");
        const built_in = builtInOf(connection.Name.parse(name) orelse return false) orelse return false;
        return built_in.runsTool(tool);
    }
};

/// A built-in provider as a served entry, named by its enum tag.
pub fn builtIn(provider: Provider, route: Route) Entry {
    return .{
        .name = connection.Name.parse(@tagName(provider)).?,
        .label = Label.parse(provider.shown()).?,
        .route = route,
        .codec = provider.codec(),
        .web_search = provider.runsTool("web_search"),
    };
}

/// The built-in provider a name spells. Until the Host's provider enum gives
/// way to connection names (commits 3-6), the boundary that hands a Session's
/// provider to enum-typed code calls this; a name that is not built in has none.
pub fn builtInOf(name: connection.Name) ?Provider {
    return std.meta.stringToEnum(Provider, name.slice());
}

/// Every built-in provider served at one route, for test fixtures.
pub fn builtIns(route: Route) Served {
    var served: Served = .{};
    inline for (std.enums.values(Provider)) |provider| served.put(builtIn(provider, route)) catch unreachable;
    return served;
}

/// A bounded set of connection names: at most `max_served`, each once. The
/// keyed container for anything a Host serves, in place of an enum set.
pub const NameSet = struct {
    names: [max_served]connection.Name = undefined,
    len: usize = 0,

    pub fn insert(self: *NameSet, name: connection.Name) error{ServedFull}!void {
        if (self.contains(name)) return;
        if (self.len == max_served) return error.ServedFull;
        self.names[self.len] = name;
        self.len += 1;
    }

    pub fn contains(self: *const NameSet, name: connection.Name) bool {
        for (self.slice()) |*one| if (one.eql(name)) return true;
        return false;
    }

    pub fn slice(self: *const NameSet) []const connection.Name {
        return self.names[0..self.len];
    }
};

/// A bounded map from connection name to a value, at most `max_served` names.
/// Looked up by name; an absent name has no value.
pub fn NameArray(comptime T: type) type {
    return struct {
        const Self = @This();

        names: [max_served]connection.Name = undefined,
        values: [max_served]T = undefined,
        len: usize = 0,

        pub fn set(self: *Self, name: connection.Name, value: T) error{ServedFull}!void {
            for (self.names[0..self.len], 0..) |*one, index| {
                if (one.eql(name)) {
                    self.values[index] = value;
                    return;
                }
            }
            if (self.len == max_served) return error.ServedFull;
            self.names[self.len] = name;
            self.values[self.len] = value;
            self.len += 1;
        }

        pub fn get(self: *const Self, name: connection.Name) ?T {
            for (self.names[0..self.len], self.values[0..self.len]) |*one, value| {
                if (one.eql(name)) return value;
            }
            return null;
        }
    };
}

/// The label a name is shown under: the served entry's label, else the
/// built-in provider's own, else the name itself. The one display lookup by name.
pub fn shownOf(served: *const Served, name: connection.Name) []const u8 {
    if (served.of(name.slice())) |entry| return entry.label.slice();
    if (builtInOf(name)) |provider| return provider.shown();
    return name.slice();
}

/// The login command a name is pointed at, or null when it has none: only a
/// built-in provider names one.
pub fn loginOf(name: connection.Name) ?[]const u8 {
    return if (builtInOf(name)) |provider| provider.login() else null;
}

test "CM-49 served lookup finds exactly the listed names" {
    var served: Served = .{};
    try std.testing.expect(!served.servesModel());
    try std.testing.expectEqual(@as(?*const Entry, null), served.of("codex"));
    const codex = builtIn(.codex, .endpoint);
    try served.put(codex);
    try served.put(builtIn(.chatgpt, .chatgpt_plan));
    try std.testing.expect(served.servesModel());
    try std.testing.expectEqual(Route.endpoint, served.of("codex").?.route);
    try std.testing.expectEqual(Route.chatgpt_plan, served.of("chatgpt").?.route);
    // Absent, prefix, and case-variant names never match a listed name.
    for ([_][]const u8{ "openai", "cod", "codexx", "Codex", "CHATGPT", "", "chatgpt-" }) |name| {
        try std.testing.expectEqual(@as(?*const Entry, null), served.of(name));
    }
    // Exactly the listed names fill the set, and no more than max_served.
    var full: Served = .{};
    var buffer: [max_served + 1][8]u8 = undefined;
    for (0..max_served) |index| {
        const name = std.fmt.bufPrint(&buffer[index], "c{d}", .{index}) catch unreachable;
        var entry = codex;
        entry.name = connection.Name.parse(name).?;
        try full.put(entry);
    }
    try std.testing.expectEqual(@as(usize, max_served), full.items().len);
    try std.testing.expect(full.of("c15") != null);
    try std.testing.expect(full.of("c16") == null);
    try std.testing.expectError(error.ServedFull, full.put(codex));
    try std.testing.expect(full.of("codex") == null);
}

test "built-in entries carry each provider's codec and web_search" {
    const served = builtIns(.endpoint);
    try std.testing.expectEqual(@as(usize, 3), served.items().len);
    for (std.enums.values(Provider)) |provider| {
        const entry = served.of(@tagName(provider)).?;
        try std.testing.expectEqual(provider.codec(), entry.codec);
        try std.testing.expect(entry.web_search);
        try std.testing.expectEqual(Route.endpoint, entry.route);
    }
}

test "NameSet and NameArray key by exact name within the served bound" {
    var set: NameSet = .{};
    try set.insert(connection.Name.parse("alpha").?);
    try set.insert(connection.Name.parse("alpha").?);
    try std.testing.expectEqual(@as(usize, 1), set.slice().len);
    try std.testing.expect(set.contains(connection.Name.parse("alpha").?));
    try std.testing.expect(!set.contains(connection.Name.parse("alph").?));
    var full: NameSet = .{};
    var buffer: [max_served + 1][4]u8 = undefined;
    for (0..max_served) |index| try full.insert(connection.Name.parse(std.fmt.bufPrint(&buffer[index], "c{d}", .{index}) catch unreachable).?);
    try std.testing.expectError(error.ServedFull, full.insert(connection.Name.parse("extra").?));

    var array: NameArray(u8) = .{};
    try array.set(connection.Name.parse("alpha").?, 1);
    try array.set(connection.Name.parse("beta").?, 2);
    try array.set(connection.Name.parse("alpha").?, 3);
    try std.testing.expectEqual(@as(usize, 2), array.len);
    try std.testing.expectEqual(@as(?u8, 3), array.get(connection.Name.parse("alpha").?));
    try std.testing.expectEqual(@as(?u8, null), array.get(connection.Name.parse("openai").?));
}

test "a name's display label and login come from its served entry or built-in facts" {
    var served: Served = .{};
    try served.put(builtIn(.codex, .endpoint));
    try served.put(.{ .name = connection.Name.parse("alpha").?, .label = Label.parse("Alpha Gateway").?, .route = .key_file, .codec = .@"openai-responses/3", .web_search = false });
    try std.testing.expectEqualStrings("Alpha Gateway", shownOf(&served, connection.Name.parse("alpha").?));
    try std.testing.expectEqualStrings("ChatGPT (device code)", shownOf(&served, connection.Name.parse("codex").?));
    try std.testing.expectEqualStrings("beta", shownOf(&served, connection.Name.parse("beta").?));
    try std.testing.expectEqualStrings("rui auth login chatgpt --device-code", loginOf(connection.Name.parse("codex").?).?);
    try std.testing.expectEqual(@as(?[]const u8, null), loginOf(connection.Name.parse("alpha").?));
}
