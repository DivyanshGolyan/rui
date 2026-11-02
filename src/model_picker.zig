//! The model picker's list: each model a served sign-in offers, once, with
//! the sign-ins that offer it. The saved default comes first, then the
//! models Rui's table knows in the table's order, then the others by name.
const std = @import("std");
const model_capability = @import("model_capability.zig");
const model_list = @import("model_list.zig");
const provider_name = @import("provider_name.zig");

pub const Provider = provider_name.Provider;
pub const Providers = std.enums.EnumSet(Provider);

/// The rank of a model the table does not list: after every row.
const unlisted: u16 = model_capability.models.len;

pub const Entry = struct {
    id: []const u8,
    /// Its row in Rui's table, or `unlisted`.
    rank: u16,
    /// The served sign-ins whose list holds it; never empty.
    providers: Providers,

    /// Rui's table knows its limits; otherwise it runs with default limits.
    pub fn known(self: Entry) bool {
        return self.rank != unlisted;
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        if (a.rank != b.rank) return a.rank < b.rank;
        return std.mem.order(u8, a.id, b.id) == .lt;
    }
};

/// What the Host said of each sign-in's list; null for one it does not serve.
pub const Sources = std.enums.EnumArray(Provider, ?model_list.Source);

/// Owns its entries and their IDs; `deinit` frees both.
pub const Menu = struct {
    entries: []Entry = &.{},
    /// Every entry's ID, back to back.
    ids: []u8 = &.{},
    sources: Sources = .initFill(null),
    /// `entries[0]` is the default, moved ahead of its place.
    led: bool = false,
    /// Where "Other models" starts: the first entry after the default that
    /// the table does not know.
    others: usize = 0,
    /// The longest ID's bytes, which are its cells: IDs are printable ASCII.
    widest: usize = 0,

    pub fn deinit(self: *Menu, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        gpa.free(self.ids);
        self.* = .{};
    }

    pub fn find(self: *const Menu, id: []const u8) ?usize {
        for (self.entries, 0..) |entry, at| if (std.mem.eql(u8, entry.id, id)) return at;
        return null;
    }

    /// Some served list is still being fetched: ask again later.
    pub fn loading(self: *const Menu) bool {
        for (self.sources.values) |source| if (source == .pending) return true;
        return false;
    }

    /// Puts `default` first and every other entry back in its place.
    pub fn lead(self: *Menu, default: ?[]const u8) void {
        if (self.led) {
            const moved = self.entries[0];
            const rest = self.entries[1..];
            const place = for (rest, 0..) |entry, at| {
                if (Entry.lessThan({}, moved, entry)) break at;
            } else rest.len;
            std.mem.rotate(Entry, self.entries[0 .. place + 1], 1);
            self.led = false;
        }
        if (default) |id| if (self.find(id)) |at| {
            std.mem.rotate(Entry, self.entries[0 .. at + 1], at);
            self.led = true;
        };
        const first = @intFromBool(self.led);
        self.others = for (self.entries[first..], first..) |entry, at| {
            if (!entry.known()) break at;
        } else self.entries.len;
    }
};

/// The menu of a `model_list` reply's `providers` array, owned by `gpa`,
/// with no default leading. A reply Rui cannot read is
/// error.InvalidModelList.
pub fn read(gpa: std.mem.Allocator, providers: []const u8) error{ OutOfMemory, InvalidModelList }!Menu {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    var scanner: std.json.Scanner = .initCompleteInput(temporary, providers);
    var menu: Menu = .{};
    // Every offered model, before merging. Each has an `"id":` member, and
    // an ID's own quotes are escaped, so this count bounds them.
    const offered = try temporary.alloc(Entry, std.mem.count(u8, providers, "\"id\":"));
    var count: usize = 0;
    if (try nextToken(&scanner, temporary) != .array_begin) return error.InvalidModelList;
    while (true) {
        switch (try nextToken(&scanner, temporary)) {
            .array_end => break,
            .object_begin => {},
            else => return error.InvalidModelList,
        }
        var provider: ?Provider = null;
        var source: ?model_list.Source = null;
        var models: ?[2]usize = null;
        while (try objectKey(&scanner, temporary)) |key| {
            if (std.mem.eql(u8, key, "provider")) {
                provider = std.meta.stringToEnum(Provider, try string(&scanner, temporary)) orelse return error.InvalidModelList;
            } else if (std.mem.eql(u8, key, "source")) {
                source = std.meta.stringToEnum(model_list.Source, try string(&scanner, temporary)) orelse return error.InvalidModelList;
            } else if (std.mem.eql(u8, key, "models")) {
                const start = count;
                if (try nextToken(&scanner, temporary) != .array_begin) return error.InvalidModelList;
                while (true) {
                    switch (try nextToken(&scanner, temporary)) {
                        .array_end => break,
                        .object_begin => {},
                        else => return error.InvalidModelList,
                    }
                    var id: ?[]const u8 = null;
                    var known: ?bool = null;
                    while (try objectKey(&scanner, temporary)) |member| {
                        if (std.mem.eql(u8, member, "id")) {
                            // Unescaped, it borrows `providers`; escaped, the scratch.
                            id = try string(&scanner, temporary);
                        } else if (std.mem.eql(u8, member, "known")) {
                            known = switch (try nextToken(&scanner, temporary)) {
                                .true => true,
                                .false => false,
                                else => return error.InvalidModelList,
                            };
                        } else return error.InvalidModelList;
                    }
                    const model = id orelse return error.InvalidModelList;
                    if (!model_capability.validModelSyntax(model)) return error.InvalidModelList;
                    // The Host and this client share one table.
                    const rank = rankOf(model);
                    if (known != (rank != unlisted)) return error.InvalidModelList;
                    if (count == offered.len) return error.InvalidModelList;
                    offered[count] = .{ .id = model, .rank = rank, .providers = .empty };
                    count += 1;
                }
                models = .{ start, count };
            } else return error.InvalidModelList;
        }
        const served = provider orelse return error.InvalidModelList;
        const span = models orelse return error.InvalidModelList;
        if (menu.sources.get(served) != null) return error.InvalidModelList;
        menu.sources.set(served, source orelse return error.InvalidModelList);
        for (offered[span[0]..span[1]]) |*entry| entry.providers = .initOne(served);
    }
    if (try nextToken(&scanner, temporary) != .end_of_document) return error.InvalidModelList;
    // One entry per ID, in place: equal IDs share a rank, so they are adjacent.
    std.mem.sort(Entry, offered[0..count], {}, Entry.lessThan);
    var len: usize = 0;
    var id_bytes: usize = 0;
    for (offered[0..count]) |entry| {
        if (len != 0 and std.mem.eql(u8, offered[len - 1].id, entry.id)) {
            offered[len - 1].providers.setUnion(entry.providers);
            continue;
        }
        offered[len] = entry;
        id_bytes += entry.id.len;
        len += 1;
    }
    menu.entries = try gpa.alloc(Entry, len);
    errdefer gpa.free(menu.entries);
    menu.ids = try gpa.alloc(u8, id_bytes);
    var at: usize = 0;
    for (offered[0..len], menu.entries) |entry, *kept| {
        @memcpy(menu.ids[at..][0..entry.id.len], entry.id);
        kept.* = entry;
        kept.id = menu.ids[at..][0..entry.id.len];
        at += entry.id.len;
        menu.widest = @max(menu.widest, entry.id.len);
    }
    menu.lead(null);
    return menu;
}

fn rankOf(id: []const u8) u16 {
    for (model_capability.models, 0..) |row, rank| if (std.mem.eql(u8, row.id, id)) return @intCast(rank);
    return unlisted;
}

fn nextToken(scanner: *std.json.Scanner, scratch: std.mem.Allocator) error{ OutOfMemory, InvalidModelList }!std.json.Token {
    return scanner.nextAlloc(scratch, .alloc_if_needed) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidModelList,
    };
}

fn string(scanner: *std.json.Scanner, scratch: std.mem.Allocator) error{ OutOfMemory, InvalidModelList }![]const u8 {
    return switch (try nextToken(scanner, scratch)) {
        .string, .allocated_string => |text| text,
        else => error.InvalidModelList,
    };
}

/// The next member's key, or null at the object's end.
fn objectKey(scanner: *std.json.Scanner, scratch: std.mem.Allocator) error{ OutOfMemory, InvalidModelList }!?[]const u8 {
    return switch (try nextToken(scanner, scratch)) {
        .object_end => null,
        .string, .allocated_string => |key| key,
        else => error.InvalidModelList,
    };
}

/// The menu of `lists` as the Host writes them, owned by the testing
/// allocator.
pub fn testMenu(lists: []const model_list.Entry) !Menu {
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    try model_list.writeProviders(&bytes.writer, lists);
    return read(std.testing.allocator, bytes.written());
}

fn expectOrder(menu: *const Menu, ids: []const []const u8) !void {
    try std.testing.expectEqual(ids.len, menu.entries.len);
    for (ids, menu.entries) |id, entry| try std.testing.expectEqualStrings(id, entry.id);
}

test "the default leads, known models follow in table order, then the others by name, each once with every sign-in that offers it" {
    var menu = try testMenu(&.{
        .{ .provider = .codex, .list = .table },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "whisper-1\ngpt-6-luna\ndall-e-3\ngpt-5.5\n" } } },
    });
    defer menu.deinit(std.testing.allocator);
    menu.lead("gpt-6-sol");
    var expected: [model_capability.models.len + 2][]const u8 = undefined;
    expected[0] = "gpt-6-sol";
    var at: usize = 1;
    for (model_capability.models) |row| if (!std.mem.eql(u8, row.id, "gpt-6-sol")) {
        expected[at] = row.id;
        at += 1;
    };
    expected[at..][0..2].* = .{ "dall-e-3", "whisper-1" };
    try expectOrder(&menu, &expected);
    for (menu.entries) |entry| {
        const both = std.mem.eql(u8, entry.id, "gpt-6-luna") or std.mem.eql(u8, entry.id, "gpt-5.5");
        const live_only = std.mem.eql(u8, entry.id, "dall-e-3") or std.mem.eql(u8, entry.id, "whisper-1");
        try std.testing.expectEqual(!live_only, entry.providers.contains(.codex));
        try std.testing.expectEqual(both or live_only, entry.providers.contains(.openai));
        try std.testing.expectEqual(!live_only, entry.known());
    }
    try std.testing.expectEqual(model_capability.models.len, menu.others);
    try std.testing.expectEqual("gpt-5.6-terra".len, menu.widest);
    try std.testing.expectEqual(@as(?model_list.Source, .live), menu.sources.get(.openai));
    try std.testing.expect(!menu.loading());
    // A new default leads, and the old one goes back to its row.
    menu.lead("gpt-5.5");
    expected[0] = "gpt-5.5";
    for (model_capability.models[0 .. model_capability.models.len - 1], 1..) |row, place| expected[place] = row.id;
    try expectOrder(&menu, &expected);
    // An unlisted default leads, and "Other models" starts at the rest.
    menu.lead("whisper-1");
    try std.testing.expectEqualStrings("whisper-1", menu.entries[0].id);
    try std.testing.expectEqual(model_capability.models.len + 1, menu.others);
    try std.testing.expectEqualStrings("dall-e-3", menu.entries[menu.others].id);
    menu.lead(null);
    try std.testing.expectEqualStrings("gpt-6-luna", menu.entries[0].id);
    try std.testing.expectEqualStrings("whisper-1", menu.entries[menu.entries.len - 1].id);
}

test "a sign-in the Host does not serve has no source, and a pending list asks again" {
    var menu = try testMenu(&.{.{ .provider = .openai, .list = .pending }});
    defer menu.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?model_list.Source, null), menu.sources.get(.codex));
    try std.testing.expect(menu.loading());
    try std.testing.expectEqualStrings("gpt-6-luna", menu.entries[0].id);
    try std.testing.expectEqual(@as(?usize, 1), menu.find("gpt-6.1-sol"));
    try std.testing.expectEqual(menu.entries.len, menu.others);
    var nothing = try testMenu(&.{});
    defer nothing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), nothing.entries.len);
}

test "a reply Rui cannot read is refused whole" {
    for ([_][]const u8{
        "",
        "{}",
        "[{\"provider\":\"claude\",\"source\":\"table\",\"models\":[]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"a b\",\"known\":false}]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-luna\",\"known\":false}]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\"}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[]},{\"provider\":\"openai\",\"source\":\"table\",\"models\":[]}]",
        "[] []",
    }) |reply| try std.testing.expectError(error.InvalidModelList, read(std.testing.allocator, reply));
}
