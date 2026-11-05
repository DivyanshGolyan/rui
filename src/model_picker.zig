//! The model picker's list: each model a served sign-in offers, once, with
//! the sign-ins that offer it. The models the Host knows come first, in Rui's
//! catalog's order, then the others by name; the picker shows the default
//! ahead of them all.
const std = @import("std");
const catalog = @import("model_catalog.zig");
const model_capability = @import("model_capability.zig");
const model_list = @import("model_list.zig");
const provider_name = @import("provider_name.zig");

pub const Provider = provider_name.Provider;
pub const Providers = std.enums.EnumSet(Provider);

pub const Entry = struct {
    id: []const u8,
    /// The Host knows its limits; otherwise it runs with default limits.
    known: bool,
    /// Local catalog membership only orders ties within the Host's groups.
    catalogued: bool,
    /// The served sign-ins whose list holds it; never empty.
    providers: Providers,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        if (a.known != b.known) return a.known;
        // The catalog is bytewise sorted. Its entries precede unlisted IDs.
        if (a.catalogued != b.catalogued) return a.catalogued;
        return std.mem.order(u8, a.id, b.id) == .lt;
    }

    fn idLessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.id, b.id) == .lt;
    }
};

/// What the Host said of each sign-in's list; null for one it does not serve.
pub const Sources = std.enums.EnumArray(Provider, ?model_list.Source);

/// Owns its entries and their IDs; `deinit` frees both. `read` fixes the
/// order, and nothing changes it after.
pub const Menu = struct {
    entries: []const Entry = &.{},
    /// Every entry's ID, back to back.
    ids: []u8 = &.{},
    sources: Sources = .initFill(null),
    /// The first entry the Host does not know.
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

    /// The menu as the picker shows it, with `default` first.
    pub fn shown(self: *const Menu, default: ?[]const u8) Shown {
        return .{ .menu = self, .lead = if (default) |id| self.find(id) else null };
    }
};

/// A menu's rows with its default's entry, `lead`, first and the rest in
/// the menu's order.
pub const Shown = struct {
    menu: *const Menu,
    lead: ?usize,

    pub fn entry(self: Shown, at_row: usize) Entry {
        const lead = self.lead orelse return self.menu.entries[at_row];
        if (at_row == 0) return self.menu.entries[lead];
        return self.menu.entries[if (at_row <= lead) at_row - 1 else at_row];
    }

    /// The row of the menu's entry `at`.
    pub fn row(self: Shown, at: usize) usize {
        const lead = self.lead orelse return at;
        return if (at == lead) 0 else if (at < lead) at + 1 else at;
    }

    /// The row "Other models" starts at.
    pub fn others(self: Shown) usize {
        const lead = self.lead orelse return self.menu.others;
        return self.menu.others + @intFromBool(lead >= self.menu.others);
    }
};

/// The menu of a `model_list` reply's `providers` array, owned by `gpa`. A
/// reply Rui cannot read is error.InvalidModelList.
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
                    if (count == offered.len) return error.InvalidModelList;
                    offered[count] = .{ .id = model, .known = known orelse return error.InvalidModelList, .catalogued = model_capability.supportsModel(model), .providers = .empty };
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
    // One entry per ID, in place, known if any sign-in's list knows it.
    std.mem.sort(Entry, offered[0..count], {}, Entry.idLessThan);
    var len: usize = 0;
    var id_bytes: usize = 0;
    for (offered[0..count]) |entry| {
        if (len != 0 and std.mem.eql(u8, offered[len - 1].id, entry.id)) {
            offered[len - 1].providers.setUnion(entry.providers);
            offered[len - 1].known = offered[len - 1].known or entry.known;
            continue;
        }
        offered[len] = entry;
        id_bytes += entry.id.len;
        len += 1;
    }
    std.mem.sort(Entry, offered[0..len], {}, Entry.lessThan);
    const entries = try gpa.alloc(Entry, len);
    errdefer gpa.free(entries);
    menu.ids = try gpa.alloc(u8, id_bytes);
    var at: usize = 0;
    menu.others = len;
    for (offered[0..len], entries, 0..) |entry, *kept, place| {
        @memcpy(menu.ids[at..][0..entry.id.len], entry.id);
        kept.* = entry;
        kept.id = menu.ids[at..][0..entry.id.len];
        at += entry.id.len;
        menu.widest = @max(menu.widest, entry.id.len);
        if (!entry.known and menu.others == len) menu.others = place;
    }
    menu.entries = entries;
    return menu;
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

fn expectOrder(shown: Shown, ids: []const []const u8) !void {
    try std.testing.expectEqual(ids.len, shown.menu.entries.len);
    for (ids, 0..) |id, row| {
        try std.testing.expectEqualStrings(id, shown.entry(row).id);
        try std.testing.expectEqual(row, shown.row(shown.menu.find(id).?));
    }
}

test "the default leads, known models follow in catalog order, then the others by name, each once with every sign-in that offers it" {
    var menu = try testMenu(&.{
        .{ .provider = .codex, .list = .catalog },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = "zz-unlisted\ngpt-6-luna\naa-unlisted\ngpt-5.5\n" } } },
    });
    defer menu.deinit(std.testing.allocator);
    var expected: [catalog.openai_ids.len + 2][]const u8 = undefined;
    expected[0] = "gpt-6-sol";
    var at: usize = 1;
    for (catalog.openai_ids) |id| if (!std.mem.eql(u8, id, "gpt-6-sol")) {
        expected[at] = id;
        at += 1;
    };
    expected[at..][0..2].* = .{ "aa-unlisted", "zz-unlisted" };
    try expectOrder(menu.shown("gpt-6-sol"), &expected);
    for (menu.entries) |entry| {
        const both = std.mem.eql(u8, entry.id, "gpt-6-luna") or std.mem.eql(u8, entry.id, "gpt-5.5");
        const live_only = std.mem.eql(u8, entry.id, "aa-unlisted") or std.mem.eql(u8, entry.id, "zz-unlisted");
        try std.testing.expectEqual(!live_only, entry.providers.contains(.codex));
        try std.testing.expectEqual(both or live_only, entry.providers.contains(.openai));
        try std.testing.expectEqual(!live_only, entry.known);
    }
    try std.testing.expectEqual(catalog.openai_ids.len, menu.shown("gpt-6-sol").others());
    var widest: usize = "zz-unlisted".len;
    for (catalog.openai_ids) |id| widest = @max(widest, id.len);
    try std.testing.expectEqual(widest, menu.widest);
    try std.testing.expectEqual(@as(?model_list.Source, .live), menu.sources.get(.openai));
    try std.testing.expect(!menu.loading());
    // Another default leads, and the first one is back in its row.
    expected[0] = "gpt-5.5";
    at = 1;
    for (catalog.openai_ids) |id| if (!std.mem.eql(u8, id, "gpt-5.5")) {
        expected[at] = id;
        at += 1;
    };
    try expectOrder(menu.shown("gpt-5.5"), &expected);
    // An unlisted default leads, and "Other models" starts at the rest.
    const unlisted_first = menu.shown("zz-unlisted");
    try std.testing.expectEqualStrings("zz-unlisted", unlisted_first.entry(0).id);
    try std.testing.expectEqual(catalog.openai_ids.len + 1, unlisted_first.others());
    try std.testing.expectEqualStrings("aa-unlisted", unlisted_first.entry(unlisted_first.others()).id);
    for ([_]?[]const u8{ null, "o9" }) |absent| {
        const plain = menu.shown(absent);
        try std.testing.expectEqualStrings(catalog.openai_ids[0], plain.entry(0).id);
        try std.testing.expectEqualStrings("zz-unlisted", plain.entry(menu.entries.len - 1).id);
    }
}

test "the Host's word decides which models are known; Rui's catalog only orders them" {
    var menu = try read(std.testing.allocator, "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[" ++
        "{\"id\":\"o9\",\"known\":false},{\"id\":\"gpt-6-luna\",\"known\":false},{\"id\":\"zz-next\",\"known\":true},{\"id\":\"gpt-5.5\",\"known\":true}]}]");
    defer menu.deinit(std.testing.allocator);
    try expectOrder(menu.shown(null), &.{ "gpt-5.5", "zz-next", "gpt-6-luna", "o9" });
    try std.testing.expectEqual(@as(usize, 2), menu.others);
    try std.testing.expect(menu.entries[1].known and !menu.entries[2].known);
}

test "a sign-in the Host does not serve has no source, and a pending list asks again" {
    var menu = try testMenu(&.{.{ .provider = .openai, .list = .pending }});
    defer menu.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?model_list.Source, null), menu.sources.get(.codex));
    try std.testing.expect(menu.loading());
    try std.testing.expectEqualStrings(catalog.openai_ids[0], menu.entries[0].id);
    try std.testing.expect(menu.find("gpt-6.1-sol") != null);
    try std.testing.expectEqual(menu.entries.len, menu.others);
    var nothing = try testMenu(&.{});
    defer nothing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), nothing.entries.len);
}

test "a reply Rui cannot read is refused whole" {
    for ([_][]const u8{
        "",
        "{}",
        "[{\"provider\":\"codex\",\"source\":\"table\",\"models\":[]}]",
        "[{\"provider\":\"openai\",\"source\":\"table_fallback\",\"models\":[]}]",
        "[{\"provider\":\"claude\",\"source\":\"catalog\",\"models\":[]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"a b\",\"known\":false}]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[{\"id\":\"gpt-6-luna\"}]}]",
        "[{\"provider\":\"openai\",\"source\":\"live\"}]",
        "[{\"provider\":\"openai\",\"source\":\"live\",\"models\":[]},{\"provider\":\"openai\",\"source\":\"catalog\",\"models\":[]}]",
        "[] []",
    }) |reply| try std.testing.expectError(error.InvalidModelList, read(std.testing.allocator, reply));
}
